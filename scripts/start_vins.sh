#!/usr/bin/env bash
#
# One-click launcher for VINS-Fusion (ROS2 Humble) with the calibrated
# RealSense D435i IR stereo + IMU setup.
#
#   scripts/start_vins.sh              camera + vins_node
#   scripts/start_vins.sh --rviz       + RViz2
#   scripts/start_vins.sh --loop       + loop closure (loop_fusion_node)
#   scripts/start_vins.sh --record     + save trajectory to CSV
#   scripts/start_vins.sh --all        everything above
#   scripts/start_vins.sh --bag DIR    replay a ros2 bag instead of the live camera
#   scripts/start_vins.sh -h           help
#
# Ctrl+C stops everything it started.
#
# Paths are resolved from this script's location; the colcon workspace
# (the directory containing install/ and src/) defaults to $HOME/vins_ws and
# can be overridden with the VINS_WS env var. Logs go to $VINS_LOG_DIR
# (default /tmp/opencode/vins_logs).
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
WS="${VINS_WS:-$HOME/vins_ws}"

CFG="$REPO/config/d435i_ir_stereo_imu_no_emitter/d435i_stereo_imu_config.yaml"
RVIZ_CFG="$REPO/config/vins_rviz_config.rviz"
RECORDER="$SCRIPT_DIR/record_pose.py"
LOGDIR="${VINS_LOG_DIR:-/tmp/opencode/vins_logs}"

# The Kalibr calibration was done at 640x480 -- this MUST match or VINS gets
# wrong pixel geometry and diverges. Do not change unless you recalibrate.
INFRA_PROFILE="640,480,30"
EXPECTED_WIDTH=640

USE_RVIZ=0
USE_LOOP=0
USE_RECORD=0
BAG=""

usage() {
    sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rviz)   USE_RVIZ=1 ;;
        --loop)   USE_LOOP=1 ;;
        --record) USE_RECORD=1 ;;
        --all)    USE_RVIZ=1; USE_LOOP=1; USE_RECORD=1 ;;
        --bag)    BAG="${2:-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1"; echo; usage; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------- environment
if [[ ! -f /opt/ros/humble/setup.bash ]]; then
    echo "ERROR: /opt/ros/humble not found (install ROS2 Humble first)."
    exit 1
fi
# ROS setup.bash is not nounset-safe -> disable -u while sourcing it.
set +u
# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash
if [[ ! -f "$WS/install/setup.bash" ]]; then
    echo "ERROR: workspace not built: $WS/install/setup.bash missing."
    echo "       Run:  cd $WS && colcon build --packages-select vins loop_fusion --symlink-install"
    echo "       (or point VINS_WS at the correct workspace)"
    exit 1
fi
# shellcheck disable=SC1091
source "$WS/install/setup.bash"
set -u

if [[ ! -f "$CFG" ]]; then
    echo "ERROR: config not found: $CFG"
    exit 1
fi
if [[ ! -f "$RECORDER" ]]; then
    echo "ERROR: recorder not found: $RECORDER"
    exit 1
fi
mkdir -p "$LOGDIR"

PIDS=()
cleanup() {
    echo
    echo "[start_vins] stopping..."
    # children are started with setsid -> each is its own process-group leader,
    # so killing the group also reaps nodes spawned by ros2 launch/run.
    for p in "${PIDS[@]:-}"; do
        [ -n "$p" ] || continue
        kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
    done
    sleep 2
    for p in "${PIDS[@]:-}"; do
        [ -n "$p" ] || continue
        kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null
    done
    wait 2>/dev/null
    echo "[start_vins] stopped. logs: $LOGDIR"
}
trap 'cleanup; exit 0' INT TERM

# -------------------------------------------------------------------- camera
if [[ -z "$BAG" ]]; then
    echo "[start_vins] starting RealSense D435i (IR ${INFRA_PROFILE} + IMU, emitter off)..."
    setsid ros2 launch realsense2_camera rs_launch.py \
        enable_color:=false enable_depth:=false \
        enable_infra1:=true enable_infra2:=true \
        enable_gyro:=true enable_accel:=true unite_imu_method:=2 \
        depth_module.infra_profile:=$INFRA_PROFILE enable_sync:=true \
        > "$LOGDIR/realsense.log" 2>&1 &
    PIDS+=($!)

    printf '[start_vins] waiting for camera stream '
    ok=0
    for _ in $(seq 1 40); do
        w=$(timeout 2 ros2 topic echo /camera/camera/infra1/camera_info --once --field width 2>/dev/null \
            | grep -oE '[0-9]+' | head -1)
        if [[ "$w" == "$EXPECTED_WIDTH" ]]; then ok=1; break; fi
        printf '.'
        sleep 1
    done
    printf '\n'
    if [[ $ok -ne 1 ]]; then
        echo "[start_vins] ERROR: infra stream is not ${EXPECTED_WIDTH}x480 (got '${w:-none}')."
        echo "           The calibration expects ${EXPECTED_WIDTH}x480. Check camera/USB and"
        echo "           depth_module.infra_profile. Aborting instead of running a divergent setup."
        cleanup
        exit 1
    fi
    echo "[start_vins] camera ok (${EXPECTED_WIDTH}x480)"
    ros2 param set /camera/camera depth_module.emitter_enabled 0 > /dev/null 2>&1
fi

# ----------------------------------------------------------------- estimator
echo "[start_vins] starting vins_node with $(basename "$CFG")"
setsid ros2 run vins vins_node "$CFG" > "$LOGDIR/vins.log" 2>&1 &
VINS_PID=$!
PIDS+=("$VINS_PID")

if [[ $USE_LOOP -eq 1 ]]; then
    echo "[start_vins] starting loop_fusion_node"
    setsid ros2 run loop_fusion loop_fusion_node "$CFG" > "$LOGDIR/loop_fusion.log" 2>&1 &
    PIDS+=($!)
fi

if [[ $USE_RVIZ -eq 1 ]]; then
    echo "[start_vins] starting rviz2"
    setsid rviz2 -d "$RVIZ_CFG" > "$LOGDIR/rviz.log" 2>&1 &
    PIDS+=($!)
fi

if [[ $USE_RECORD -eq 1 ]]; then
    STAMP=$(date +%Y%m%d_%H%M%S)
    TRAJ="$LOGDIR/trajectory_$STAMP.csv"
    echo "[start_vins] recording /camera_pose -> $TRAJ"
    setsid python3 "$RECORDER" /camera_pose "$TRAJ" > "$LOGDIR/record.log" 2>&1 &
    PIDS+=($!)
fi

if [[ -n "$BAG" ]]; then
    if [[ ! -e "$BAG" ]]; then
        echo "[start_vins] ERROR: bag not found: $BAG"; cleanup; exit 1
    fi
    echo "[start_vins] playing bag: $BAG"
    setsid ros2 bag play "$BAG" > "$LOGDIR/bagplay.log" 2>&1 &
    PIDS+=($!)
fi

echo "[start_vins] running -- press Ctrl+C to stop. logs: $LOGDIR"

# supervised wait: bail out if the estimator dies
while kill -0 "$VINS_PID" 2>/dev/null; do
    sleep 2
done
echo "[start_vins] vins_node exited unexpectedly -- see $LOGDIR/vins.log"
cleanup
