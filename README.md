# VINS-Fusion for ROS2 Humble on Jetson (aarch64)

VINS-Fusion ported to **ROS2 Humble**, adapted and tested on **NVIDIA Jetson Orin / Nano / Super** (aarch64).

## Platform

| Item | Version |
|------|---------|
| OS | Ubuntu 22.04 (JetPack 36.4.3, R36 release) |
| Kernel | 5.15.148-tegra (aarch64) |
| ROS2 | Humble |
| OpenCV | 4.10.0 (built from source with CUDA 12.6, cuDNN 9.3) |
| Eigen3 | 3.4.0 |
| Ceres Solver | 2.1.0 |
| CUDA | 12.6 (Driver 540.4.0) |
| cuDNN | 9.3.0 |

## Adaptations for Jetson ARM (aarch64)

### 1. Eigen alignment fix
Added `-DEIGEN_DONT_VECTORIZE` to all `CMakeLists.txt`. Without this, Eigen's default 16-byte alignment on ARM NEON causes `std::bad_array_new_length` during marginalization.

### 2. Multi-threading disabled by default
Set `multiple_thread: 0` in the EuRoC config. Running the estimator in a separate thread causes a Ceres parameter block conflict ("same double pointer with different block sizes") on ARM. This is under investigation — if you have a fix, PRs are welcome.

### 3. GPU acceleration (experimental)
The code includes CUDA-accelerated optical flow and feature detection (`#define GPU_MODE 1` in `feature_tracker.h`), but this has **not been fully tested on Jetson**. The GPU path compiles against OpenCV 4.10.0 with CUDA and is controlled by:
```yaml
# config/euroc/euroc_stereo_imu_config.yaml
use_gpu         : 0   # set to 1 to enable GPU feature detection
use_gpu_acc_flow: 0   # set to 1 to enable GPU optical flow
```
**Current recommendation: use CPU mode only.** See Known Issues below.

### 4. Segfault signal handler
Added a `SIGSEGV` handler with `backtrace()` in `vins_node` for easier debugging on ARM.

## Build

```bash
mkdir -p ~/vins_ws/src && cd ~/vins_ws/src
git clone https://github.com/the-ninth-moon/VINS-Fusion-ROS2-humble-arm.git
cd ~/vins_ws

# Install dependencies if needed
# sudo apt install ros-humble-cv-bridge ros-humble-image-transport

source /opt/ros/humble/setup.bash
colcon build --packages-select camera_models vins loop_fusion --symlink-install
```

## Run (EuRoC dataset)

### Step 1: Convert ROS1 bag to ROS2
```bash
pip install rosbags
rosbags-convert --src MH_01_easy.bag --dst MH_01_easy_ros2
# Fix rosbags metadata incompatibility with ROS2 Humble:
sed -i "s/offered_qos_profiles: \[\]/offered_qos_profiles: ''/g" MH_01_easy_ros2/metadata.yaml
python3 -c "
import sqlite3
db = sqlite3.connect('MH_01_easy_ros2/MH_01_easy_ros2.db3')
row = db.execute('SELECT id, metadata FROM metadata WHERE id=1').fetchone()
yaml = row[1].replace('offered_qos_profiles: []', \"offered_qos_profiles: ''\")
db.execute('UPDATE metadata SET metadata = ? WHERE id = ?', (yaml, row[0]))
db.execute(\"UPDATE topics SET offered_qos_profiles = '' WHERE offered_qos_profiles = '[]'\")
db.commit(); db.close()
"
```

### Step 2: Launch VINS-Fusion
```bash
cd ~/vins_ws && source install/setup.bash

# Terminal 1 — VINS odometry (stereo + IMU)
ros2 run vins vins_node \
  src/VINS-Fusion-ROS2-humble-arm/config/euroc/euroc_stereo_imu_config.yaml

# Terminal 2 — Loop closure (optional)
ros2 run loop_fusion loop_fusion_node \
  src/VINS-Fusion-ROS2-humble-arm/config/euroc/euroc_stereo_imu_config.yaml

# Terminal 3 — Visualize
rviz2 -d src/VINS-Fusion-ROS2-humble-arm/config/vins_rviz_config.rviz

# Terminal 4 — Play bag
ros2 bag play MH_01_easy_ros2
```

## Run (live RealSense D435i)

The D435i setup is calibrated (Kalibr) and pre-configured in
`config/d435i_ir_stereo_imu_no_emitter/`. A one-click launcher is provided:

```bash
cd ~/vins_ws/src/VINS-Fusion-ROS2-humble-arm

./scripts/start_vins.sh            # camera + VIO
./scripts/start_vins.sh --all      # + RViz, loop closure, trajectory CSV
./scripts/start_vins.sh --bag DIR  # replay a ros2 bag instead of the camera
./scripts/start_vins.sh -h
```

It starts the RealSense driver with the settings the calibration depends on,
refuses to run if the stream does not match, and Ctrl+C stops everything it
started (logs in `/tmp/opencode/vins_logs/`).

Required driver settings (the launcher sets them; keep them if you start the
camera manually):

| Setting | Value | Why |
|---|---|---|
| `depth_module.infra_profile` | `640,480,30` | the calibration is 640x480; the driver default (848x480) breaks pixel geometry and VINS diverges |
| `enable_sync` | `true` | keeps IR1/IR2 timestamps paired (~35% of frames are dropped without it) |
| `unite_imu_method` | `2` (linear_interpolation) | provides the `/camera/camera/imu` topic |
| `depth_module.emitter_enabled` | `0` | calibrated with the IR emitter off |

**Use CPU mode (`use_gpu: 0`).** GPU feature tracking / optical flow diverges
badly with the live D435i stream on Jetson: position error >100 m and vertical
drift to 85 m within seconds of moving, plus position creep after stopping.
The CPU path is accurate -- 0.19 m loop-closure error over a 28.5 m indoor walk
(0.65%) with no drift while standing still. For reference, this build reaches
0.258 m RMSE (0.32%) on EuRoC MH_01 against the Leica ground truth.

## Other Configurations

Pre-configured sensor configs available under `config/`:

| Sensor | Config Directory |
|--------|-----------------|
| EuRoC MAV (stereo + IMU) | `config/euroc/` |
| RealSense D435i | `config/d435i_ir_stereo_imu_no_emitter/` |
| KITTI Odometry | `config/kitti_odom/` |
| KITTI Raw | `config/kitti_raw/` |
| MYNTEYE | `config/mynteye/` |

## Known Issues on Jetson ARM

| Issue | Status | Workaround |
|-------|--------|------------|
| `std::bad_array_new_length` crash | Fixed | `-DEIGEN_DONT_VECTORIZE` |
| Ceres "same pointer, different block sizes" | Fixed | `multiple_thread: 0` |
| GPU optical flow / feature detection | Not tested | Set `use_gpu: 0, use_gpu_acc_flow: 0` |
| `rosbags-convert` metadata incompatibility | Workaround | See conversion fix above |

## Credits

- Original VINS-Fusion: [HKUST Aerial Robotics Group](https://github.com/HKUST-Aerial-Robotics/VINS-Fusion)
- ROS2 Humble port: [JanekDev/VINS-Fusion-ROS2-humble-arm](https://github.com/JanekDev/VINS-Fusion-ROS2-humble-arm)
- Jetson ARM adaptation: the-ninth-moon

## License

GNU General Public License v3.0 (same as upstream)
