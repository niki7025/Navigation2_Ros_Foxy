#
# ROS2 with ORBSLAM2, RTABMap, ZED, Realsense2, ODrive Robotics, Slam-toolbox, NAV2
#


# This dockerfile can be configured via --build-arg
# Build context must be the /navigation2 root folder for COPY.
# Example build command:
# export UNDERLAY_MIXINS="debug ccache"
# export OVERLAY_MIXINS="debug ccache coverage"
# docker build -t nav2:latest \
#   --build-arg UNDERLAY_MIXINS \
#   --build-arg OVERLAY_MIXINS ./

# local base image!
ARG FROM_IMAGE=ros:foxy-slam-l4t-r32.5.1
ARG UNDERLAY_WS=/opt/underlay_ws
ARG OVERLAY_WS=/opt/overlay_ws

# multi-stage for caching
FROM $FROM_IMAGE AS cacher

SHELL ["/bin/bash", "-c"] 
ENV SHELL /bin/bash

ENV DEBIAN_FRONTEND=noninteractive
ARG MAKEFLAGS=-j$(nproc)
ENV LANG=en_US.UTF-8 
ENV PYTHONIOENCODING=utf-8
RUN locale-gen en_US en_US.UTF-8 && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

ENV PYTORCH_PATH="/usr/local/lib/python3.6/dist-packages/torch"
ENV LD_LIBRARY_PATH="${PYTORCH_PATH}/lib:${LD_LIBRARY_PATH}"

ARG ROS_ENVIRONMENT=${ROS_ROOT}/install/setup.bash

# install gazebo
#WORKDIR /
#COPY ./install_gazebo.sh /
#RUN chmod +x /install_gazebo.sh && ./install_gazebo.sh
RUN sh -c 'echo "deb http://packages.osrfoundation.org/gazebo/ubuntu-stable `lsb_release -cs` main" > /etc/apt/sources.list.d/gazebo-stable.list' && \
  wget https://packages.osrfoundation.org/gazebo.key -O - | sudo apt-key add - && \
  apt-get update && \
  apt-get install -y gazebo11 \
  libgazebo11-dev \
  ros-foxy-gazebo-ros-pkgs

# install gazebo ros packages
#WORKDIR /
#RUN mkdir -p  ${ROS_ROOT}/src && \
#    cd ${ROS_ROOT} && \
#    wget https://raw.githubusercontent.com/ros-simulation/gazebo_ros_pkgs/ros2/gazebo_ros_pkgs.repos && \
#   vcs import src < gazebo_ros_pkgs.repos && \
#  vcs custom --args checkout foxy && \
#   source ${ROS_ENVIRONMENT} && \ 
#   rosdep install --from-paths src --ignore-src -r -y && \
#   colcon build --symlink-install


# clone underlay source
ARG UNDERLAY_WS
WORKDIR $UNDERLAY_WS/src
COPY ./tools/ros2_dependencies.repos ../
RUN vcs import ./ < ../ros2_dependencies.repos && \
    find ./ -name ".git" | xargs rm -rf

# copy overlay source
ARG OVERLAY_WS
WORKDIR $OVERLAY_WS/src
COPY ./ ./navigation2

# copy manifests for caching
WORKDIR /opt
RUN mkdir -p /tmp/opt && \
    find ./ -name "package.xml" | \
      xargs cp --parents -t /tmp/opt && \
    find ./ -name "COLCON_IGNORE" | \
      xargs cp --parents -t /tmp/opt || true

# multi-stage for building
FROM $FROM_IMAGE AS builder

# install CI dependencies
RUN apt-get update && apt-get install -q -y \
      ccache \
      lcov \
    && rosdep update \
    && rm -rf /var/lib/apt/lists/*

# install underlay dependencies
ARG UNDERLAY_WS
WORKDIR $UNDERLAY_WS
COPY --from=cacher /tmp/$UNDERLAY_WS ./
RUN . /opt/ros/$ROS_DISTRO/install/setup.sh && \
    apt-get update && rosdep install -q -y \
      --from-paths src \
      --rosdistro ${ROS_DISTRO} \
      --os=ubuntu:bionic \
      --skip-keys " \
        slam_toolbox \
        " \
      --ignore-src \
    && rm -rf /var/lib/apt/lists/*

# build underlay source
COPY --from=cacher $UNDERLAY_WS ./
ARG UNDERLAY_MIXINS="release ccache"
ARG FAIL_ON_BUILD_FAILURE=True
RUN . /opt/ros/$ROS_DISTRO/install/setup.sh && \
    colcon build \
      --symlink-install \
      --mixin $UNDERLAY_MIXINS \
      --event-handlers console_direct+ \
    || touch build_failed && \
    if [ -f build_failed ] && [ -n "$FAIL_ON_BUILD_FAILURE" ]; then \
      exit 1; \
    fi

# install overlay dependencies
ARG OVERLAY_WS
WORKDIR $OVERLAY_WS
COPY --from=cacher /tmp/$OVERLAY_WS ./
RUN . $UNDERLAY_WS/install/setup.sh && \
    apt-get update && rosdep install -q -y \
      --rosdistro ${ROS_DISTRO} \
      --os=ubuntu:bionic \
      --from-paths src \
        $UNDERLAY_WS/src \
      --skip-keys " \
        slam_toolbox \
        "\
      --ignore-src \
    && rm -rf /var/lib/apt/lists/*

# build overlay source
COPY --from=cacher $OVERLAY_WS ./
ARG OVERLAY_MIXINS="release ccache"
RUN . $UNDERLAY_WS/install/setup.sh && \
    colcon build \
      --symlink-install \
      --mixin $OVERLAY_MIXINS \
    || touch build_failed && \
    if [ -f build_failed ] && [ -n "$FAIL_ON_BUILD_FAILURE" ]; then \
      exit 1; \
    fi

# source overlay from entrypoint
ENV UNDERLAY_WS $UNDERLAY_WS
ENV OVERLAY_WS $OVERLAY_WS
RUN sed --in-place \
      's|^source .*|source "$OVERLAY_WS/install/setup.bash"|' \
      /ros_entrypoint.sh
