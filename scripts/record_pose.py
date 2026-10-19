#!/usr/bin/env python3
"""Record an odometry topic to CSV with full-precision timestamps.

Usage: python3 record_pose.py [topic] [out_csv]
Default: /camera_pose -> ./trajectory.csv
"""
import os
import sys

import rclpy
from nav_msgs.msg import Odometry
from rclpy.node import Node

topic = sys.argv[1] if len(sys.argv) > 1 else '/camera_pose'
outpath = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.getcwd(), 'trajectory.csv')
os.makedirs(os.path.dirname(os.path.abspath(outpath)), exist_ok=True)

out = open(outpath, 'w')
out.write('t,px,py,pz,qw,qx,qy,qz,vx,vy,vz\n')


class Rec(Node):
    def __init__(self):
        super().__init__('pose_rec')
        self.n = 0
        self.create_subscription(Odometry, topic, self.cb, 100)

    def cb(self, m):
        t = m.header.stamp.sec + m.header.stamp.nanosec * 1e-9
        p, q, v = m.pose.pose.position, m.pose.pose.orientation, m.twist.twist.linear
        out.write(f"{t:.9f},{p.x:.6f},{p.y:.6f},{p.z:.6f},"
                  f"{q.w:.6f},{q.x:.6f},{q.y:.6f},{q.z:.6f},"
                  f"{v.x:.5f},{v.y:.5f},{v.z:.5f}\n")
        self.n += 1
        if self.n % 50 == 0:
            out.flush()


rclpy.init()
node = Rec()
try:
    rclpy.spin(node)
except KeyboardInterrupt:
    pass
finally:
    out.close()
print('saved', node.n, 'poses to', outpath)
