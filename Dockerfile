# ImmortalWrt for NanoPi NEO4 —— 编译环境镜像
# 只安装编译依赖，源码在运行容器时挂载进来（见 build-immortalwrt-neo4.sh docker 用法）
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
        gettext git libncurses5-dev libssl-dev python3 python3-distutils \
        python3-setuptools python3-pyelftools python3-dev swig \
        rsync unzip zlib1g-dev file wget vim ca-certificates gdisk \
        ccache bash sudo && \
    rm -rf /var/lib/apt/lists/*

# 非 root 用户编译也可，但 ImmortalWrt 推荐在可写 HOME 下跑
WORKDIR /work
CMD ["/bin/bash"]
