#!/bin/sh
yum install -y docker

# Set mirror
sed -i 's|OPTIONS=|OPTIONS=--registry-mirror=https://docker.mirrors.ustc.edu.cn |g' /etc/sysconfig/docker

# Enable docker
systemctl enable docker
systemctl start docker

# Install docker
curl -sSL -o /usr/bin/weave https://github.com/weaveworks/weave/releases/download/v0.11.1/weave
chmod a+x /usr/bin/weave
weave setup

# Install docker images
PACKAGES=(
  busybox
  haproxy
  mongo
  nginx
  postgres
  redis
  microbox/etcd

  # Langugages
  node
  python:2.7
  python:latest
  ruby
)

for pkg in ${PACKAGES[@]}
do
  docker pull $pkg
done

