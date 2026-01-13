 + 超核电子CH110_惯导

# 1 env

1. 依赖
~~~python
sudo apt install ros-noetic-serial
~~~

2. 下载
~~~

~~~


3. 编译
~~~
cd catkin_ws
catkin_make
~~~

4. 启动
~~~python
# USB权限
sudo chmod 666 /dev/ttyUSB0(为避免多串口冲突，已对/dev/ttyUSB0重新映射为/dev/imu，端口已绑定，请勿乱插）
# 永久解决
sudo usermod -aG　dialout lin(用户名)

# 启动
rosrun imu_pkg imu_node
~~~

---

# 编译问题
1. `Could not find serialConfig.cmake`
~~~c
Could not find a package configuration file provided by "serial" with any
  of the following names:
    serialConfig.cmake
    serial-config.cmake
~~~

+ 安装`ros-noetic-serial`
~~~python
sudo apt install ros-noetic-serial
~~~

2. 启动时报错`[ERROR] [1687935551.437507487]: Unable to open port.`

~~~python
sudo chmod 666 /dev/ttyUSB0
~~~

`/dev/ttyUSB0 denied permission`永久解决方案
~~~python
sudo usermod -aG　dialout lin(用户名)
~~~

# 2 启动

+ 消息话题名自己在`src/serial_imu.cpp`修改 IMU_pub的参数

~~~python
# 原版
rosrun serial_port serial_imu

# 改版
rosrun imu_pkg imu_node
~~~

1. launch启动

+ 注意代码中imu是相对于base_link系

~~~
roslaunch imu_pkg imu_node.launch

roslaunch imu_pkg view.launch
~~~
