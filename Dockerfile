ARG ROS_DISTRO=galactic

FROM ros:$ROS_DISTRO-ros-core

SHELL ["/bin/bash", "-c"]

RUN apt-get update && apt-get upgrade -y && apt-get install -y \
        ros-$ROS_DISTRO-rmw-fastrtps-cpp \
        ros-$ROS_DISTRO-rmw-cyclonedds-cpp \
		gettext-base && \
    apt-get upgrade -y && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY ./ros_entrypoint.sh /

ENV RMW_IMPLEMENTATION=rmw_fastrtps_cpp

RUN echo ". /opt/ros/$ROS_DISTRO/setup.bash" >> ~/.bashrc
