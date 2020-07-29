#!/usr/bin/env bash
set -xe

# shellcheck disable=SC1091
source lib/logging.sh
# shellcheck disable=SC1091
source lib/common.sh

if [[ $(id -u) == 0 ]]; then
  echo "Please run 'make' as a non-root user"
  exit 1
fi

if [[ $OS == ubuntu ]]; then
  # shellcheck disable=SC1091
  source ubuntu_install_requirements.sh
else
  # shellcheck disable=SC1091
  source centos_install_requirements.sh
fi

# shellcheck disable=SC1091
source lib/network.sh
# shellcheck disable=SC1091
source lib/images.sh

# Install requirements
ansible-galaxy install -r vm-setup/requirements.yml

ANSIBLE_FORCE_COLOR=true ansible-playbook \
  -e "working_dir=$WORKING_DIR" \
  -e "virthost=$HOSTNAME" \
  -i vm-setup/inventory.ini \
  -b -vvv vm-setup/install-package-playbook.yml

# Allow local non-root-user access to libvirt
# Restart libvirtd service to get the new group membership loaded
if ! id "$USER" | grep -q libvirt; then
  sudo usermod -a -G "libvirt" "$USER"
  sudo systemctl restart libvirtd
fi

if [ "${EPHEMERAL_CLUSTER}" == "minikube" ]; then
  if ! command -v minikube 2>/dev/null ; then
      curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
      chmod +x minikube
      sudo mv minikube /usr/local/bin/.
  fi

  if ! command -v docker-machine-driver-kvm2 2>/dev/null ; then
      curl -LO https://storage.googleapis.com/minikube/releases/latest/docker-machine-driver-kvm2
      chmod +x docker-machine-driver-kvm2
      sudo mv docker-machine-driver-kvm2 /usr/local/bin/.
  fi
elif [ "${EPHEMERAL_CLUSTER}" == "kind" ]; then
    if ! command -v kind 2>/dev/null ; then
        curl -Lo ./kind https://github.com/kubernetes-sigs/kind/releases/download/"${KIND_VERSION}"/kind-"$(uname)"-amd64
        chmod +x ./kind
        sudo mv kind /usr/local/bin/.
    fi
fi

KUBECTL_LATEST=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
KUBECTL_LOCAL=$(kubectl version --client --short | cut -d ":" -f2 | sed 's/[[:space:]]//g' 2> /dev/null)
KUBECTL_PATH=$(whereis -b kubectl | cut -d ":" -f2 | awk '{print $1}')

if [ "$KUBECTL_LOCAL" != "$KUBECTL_LATEST" ]; then
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_LATEST}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    KUBECTL_PATH="${KUBECTL_PATH:-/usr/local/bin/kubectl}"
    sudo mv kubectl "${KUBECTL_PATH}"
fi

if ! command -v kustomize 2>/dev/null ; then
    curl -L -O "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
    tar -xzvf "kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
    chmod +x kustomize
    sudo mv kustomize /usr/local/bin/.
    rm "kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
fi

# Clean-up any old ironic containers
for name in ironic ironic-inspector dnsmasq httpd mariadb ipa-downloader; do
    sudo "${CONTAINER_RUNTIME}" ps | grep -w "$name$" && sudo "${CONTAINER_RUNTIME}" kill $name
    sudo "${CONTAINER_RUNTIME}" ps --all | grep -w "$name$" && sudo "${CONTAINER_RUNTIME}" rm $name -f
done

# Clean-up existing pod, if podman
case $CONTAINER_RUNTIME in
podman)
  for pod in ironic-pod infra-pod; do
    if  sudo "${CONTAINER_RUNTIME}" pod exists "${pod}" ; then
        sudo "${CONTAINER_RUNTIME}" pod rm "${pod}" -f
    fi
    sudo "${CONTAINER_RUNTIME}" pod create -n "${pod}"
  done
  ;;
esac


# Download IPA and CentOS 7 Images
mkdir -p "$IRONIC_IMAGE_DIR"
pushd "$IRONIC_IMAGE_DIR"

if [ ! -f "${IMAGE_NAME}" ] ; then
    curl --insecure --compressed -O -L "${IMAGE_LOCATION}/${IMAGE_NAME}"
    qemu-img convert -O raw "${IMAGE_NAME}" "${IMAGE_RAW_NAME}"
    md5sum "${IMAGE_RAW_NAME}" | awk '{print $1}' > "${IMAGE_RAW_NAME}.md5sum"
fi
popd

# Start image downloader container
#shellcheck disable=SC2086
sudo "${CONTAINER_RUNTIME}" run -d --net host --privileged --name ipa-downloader ${POD_NAME} \
     -e IPA_BASEURI="$IPA_BASEURI" \
     -v "$IRONIC_DATA_DIR":/shared "${IPA_DOWNLOADER_IMAGE}" /usr/local/bin/get-resource.sh

sudo "${CONTAINER_RUNTIME}" wait ipa-downloader

function configure_minikube() {
    minikube config set vm-driver kvm2
    minikube config set memory 4096
}
if [ "${EPHEMERAL_CLUSTER}" == "minikube" ]; then
  configure_minikube
  init_minikube
fi
