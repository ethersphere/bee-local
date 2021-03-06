#!/usr/bin/env bash

set -eo pipefail
set -x
#/
#/ Usage:
#/ ./beeinfra.sh ACTION [OPTION]
#/
#/ Description:
#/ Spinup local k8s infra and run beekeeper tests
#/
#/ Example:
#/ ./beeinfra.sh install --test --local -r 3
#/
#/ Actions:

# parse file and print usage text
usage() { grep '^#/' "$0" | cut -c4- ; exit 0 ; }
expr "$*" : ".*-h" > /dev/null && usage
expr "$*" : ".*--help" > /dev/null && usage

declare -x DOCKER_BUILDKIT="1"
declare -x REPLICA="3"
declare -x DOMAIN="localhost"
declare -x REGISTRY="registry.${DOMAIN}:5000"
declare -x SKYDNS=""
declare -x REPO="ethersphere/bee"
declare -x HELM_SET_REPO="${REPO}"
declare -x CHART="${REPO}"
#declare -x CHART="./charts/bee"
declare -x NAMESPACE="test"
declare -x RUN_TESTS=""
declare -x DNS_DISCO=""
declare -x ACTION=""
declare -x CHAOS=""
declare -x GETH="false"
declare -x CLEF=""
declare -x K3S=""
declare -x K3S_VERSION="v1.19.5+k3s2"
declare -x K3S_URL_VERSION="v1.19.5%2Bk3s2"
declare -x DESTROY=""
declare -x LOCAL=""
declare -x IMAGE_TAG="latest"
declare -x BEE_0_HASH="16Uiu2HAm6i4dFaJt584m2jubyvnieEECgqM2YMpQ9nusXfy8XFzL"
declare -x HELM_SET_BOOTNODES="/dns4/bee-0-headless.${NAMESPACE}.svc.cluster.local/tcp/1634/p2p/${BEE_0_HASH}"
declare -x PAY_THRESHOLD=10000000000000
declare -x PAY_TOLERANCE=$((PAY_THRESHOLD/10))
declare -x PAY_EARLY=$((PAY_THRESHOLD/10))
declare -x CACHE_CAPACITY=2000
declare -x POSTAGE=""

_revdomain() {
    for((i=$#;i>0;i--));do printf "%s/" ${!i}; done
}

# arch discovers the architecture for this system
_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    armv6*) ARCH="armv6";;
    aarch64) ARCH="arm64";;
    x86) ARCH="386";;
    x86_64) ARCH="amd64";;
    i686) ARCH="386";;
    i386) ARCH="386";;
  esac
}

# os discovers the operating system for this system
_os() {
  OS=$(uname|tr '[:upper:]' '[:lower:]')
}

_install_beekeeper() {
    echo "installing beekeeper..."
    _arch
    _os
    curl -Ls https://github.com/ethersphere/beekeeper/releases/download/"${1}"/beekeeper-"${OS}"-"${ARCH}" -o beekeeper
    chmod +x beekeeper
    echo "kubeconfig: ${HOME}/.kube/config" > "${HOME}"/.beekeeper.yaml
}

_check_beekeeper() {
    TAG=$(curl -s https://api.github.com/repos/ethersphere/beekeeper/releases/latest | jq -r .tag_name)
    if [[ -f "beekeeper" ]]; then
        VERSION=$(./beekeeper version 2>&1)
        if [[ "${VERSION%%-*}" !=  "${TAG##v}" ]]; then
            rm beekeeper
            _install_beekeeper "${TAG}"
        fi
    else
        _install_beekeeper "${TAG}"
    fi
}

_check_deps() {
    if ! grep -qE "docker|admin" <<< "$(id "$(whoami)")"; then
        if (( EUID != 0 )); then
            echo "$(whoami) not member of docker group..."
            exit 1
        fi
    fi
    if ! command -v jq &> /dev/null; then
        echo "jq is missing..."
        exit 1
    elif ! command -v curl &> /dev/null; then
        echo "curl is missing..."
        exit 1
    elif ! command -v kubectl &> /dev/null; then
        echo "kubectl is missing..."
        exit 1
    elif ! command -v docker &> /dev/null; then
        echo "docker is missing..."
        exit 1
    fi

    if ! command -v helm &> /dev/null; then
        echo "helm is missing..."
        echo "installing helm..."
        curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
    fi
    # if ! command -v tilt &> /dev/null; then
    #     echo "tilt is missing..."
    #     echo "installing tilt..."
    #     curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash
    # fi
    if [[ -n $K3S ]]; then
        if ! command -v k3s &> /dev/null; then
            echo "k3s is missing..."
            echo "installing k3s.."
            K3S_FOLDER=/tmp/k3s-"${K3S_VERSION}"
            if [[ ! -d "${K3S_FOLDER}" ]]; then
                mkdir -p "${K3S_FOLDER}"
                curl -sL https://get.k3s.io -o "${K3S_FOLDER}"/k3s_install.sh
                curl -sL https://github.com/k3s-io/k3s/releases/download/"${K3S_URL_VERSION}"/k3s -o "${K3S_FOLDER}"/k3s
                curl -sL https://github.com/k3s-io/k3s/releases/download/"${K3S_URL_VERSION}"/k3s-airgap-images-amd64.tar -o "${K3S_FOLDER}"/k3s-airgap-images-amd64.tar
            fi
            sudo mkdir -p /etc/rancher/k3s/
            sudo mkdir -p /var/lib/rancher/k3s/agent/images/
            sudo mkdir -p /var/lib/rancher/k3s/server/manifests/
            cp "${K3S_FOLDER}"/k3s_install.sh .
            sudo cp "${K3S_FOLDER}"/k3s /usr/local/bin/k3s
            sudo cp "${K3S_FOLDER}"/k3s-airgap-images-amd64.tar /var/lib/rancher/k3s/agent/images/
            sudo cp hack/registries_k3s.yaml /etc/rancher/k3s/registries.yaml
            sudo cp hack/coredns-custom.yaml /var/lib/rancher/k3s/server/manifests/coredns-custom.yaml
            sudo cp hack/traefik-config.yaml /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
            sudo chmod +x k3s_install.sh /usr/local/bin/k3s
        fi
    else
        if ! command -v k3d &> /dev/null; then
            echo "k3d is missing..."
            echo "installing k3d..."
            curl -s https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=v1.7.0 bash
        fi
    fi
}

_prepare() {
    docker volume create registry &> /dev/null
    if [[ -n $CI ]]; then
        docker container run -d --name registry.localhost -v registry:/var/lib/registry --restart always -p 5000:5000 registry:2 &> /dev/null || true
    else
        docker container run -d --name registry.localhost -v registry:/var/lib/registry --restart always -p 5000:5000 registry:2 &> /dev/null || true
    fi
    if [[ -n $K3S ]]; then
        echo "starting k3s cluster..."
        INSTALL_K3S_SKIP_DOWNLOAD=true K3S_KUBECONFIG_MODE="644" INSTALL_K3S_EXEC="--disable=coredns" ./k3s_install.sh &> /dev/null
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    else
        echo "starting k3d cluster..."
        docker volume create k3d-registry &> /dev/null
        k3d create --publish="80:80" --enable-registry --registry-name k3d-registry.localhost --registry-volume k3d-registry --registry-port 5001 --enable-registry-cache --registries-file hack/registries.yaml &> /dev/null
        until k3d get-kubeconfig --name='k3s-default' &> /dev/null; do echo "waiting for the cluster..."; sleep 1; done
        docker network connect k3d-k3s-default registry.localhost &> /dev/null
        KUBECONFIG="$(k3d get-kubeconfig --name='k3s-default')"
        export KUBECONFIG
    fi
    kubectl create ns "${NAMESPACE}" &> /dev/null || true
    if [[ $(helm repo list) != *ethersphere* ]]; then
        helm repo add ethersphere https://ethersphere.github.io/helm &> /dev/null
    fi
    helm repo update &> /dev/null

    # nodes=$(kubectl get nodes -o go-template --template='{{range .items}}{{printf "%s\n" .metadata.name}}{{end}}')
    # if [ -n "${nodes}" ]; then
    #     for node in ${nodes}; do
    #         kubectl annotate node "${node}" \
    #             tilt.dev/registry=localhost:5000 \
    #             tilt.dev/registry-from-cluster=registry.localhost:5000 &> /dev/null
    #     done
    # fi

    until kubectl get svc traefik -n kube-system &> /dev/null; do echo "waiting for the kube-system..."; sleep 1; done

    if [[ -n $CHAOS ]]; then
        _chaos
    fi

    if [[ -n $DNS_DISCO ]]; then
        _dns_disco
    fi

    if [[ -n $GETH ]]; then
        _geth
    fi

    echo "cluster running..."
}

_build() {
    if [[ ! -f go.mod ]]; then
        cd "${GOPATH}"/src/github.com/ethersphere/bee
        make lint vet test-race
    fi
    if [[ -n $CI ]]; then
        if [[ -n $K3S ]]; then
            make binary
            mv dist/bee bee
            docker build -t "${REGISTRY}"/"${REPO}":"${IMAGE_TAG}" -f Dockerfile.goreleaser . --cache-from=ghcr.io/ethersphere/bee --build-arg BUILDKIT_INLINE_CACHE=1
        else
            docker build --target build -t "${REGISTRY}"/"${REPO}":build . --cache-from=ghcr.io/ethersphere/bee:build --build-arg BUILDKIT_INLINE_CACHE=1
            docker build -t "${REGISTRY}"/"${REPO}":"${IMAGE_TAG}" . --cache-from=ghcr.io/ethersphere/bee:runtime --cache-from=ghcr.io/ethersphere/bee:build --build-arg BUILDKIT_INLINE_CACHE=1
        fi
    else
        docker build --target build -t "${REGISTRY}"/"${REPO}":build . --cache-from="${REGISTRY}"/"${REPO}":build --build-arg BUILDKIT_INLINE_CACHE=1
        docker build -t "${REGISTRY}"/"${REPO}":"${IMAGE_TAG}" . --cache-from="${REGISTRY}"/"${REPO}":"${IMAGE_TAG}" --cache-from="${REGISTRY}"/"${REPO}":build --build-arg BUILDKIT_INLINE_CACHE=1
        docker push "${REGISTRY}"/"${REPO}":build
    fi
    docker push "${REGISTRY}"/"${REPO}":"${IMAGE_TAG}"
    if [[ -n ${OLDPWD+x} ]]; then
        cd - &> /dev/null
    fi
}

# if dns-discovery is enabled delete all records because of the upgrade/uninstallation
_clear_dns() {
    SKYDNS=$(_revdomain ${DOMAIN/./ })
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl del --prefix /skydns/${SKYDNS} --user=root --password=secret" &> /dev/null
}

# initial dns config with bee-0
_populate_dns_0() {
    ip="${1}"
    SKYDNS=$(_revdomain ${DOMAIN/./ })
    # shellcheck disable=SC1117,SC2059
    MOD=$(printf "\x6$((0 % 4 + 1))")
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}_dnsaddr/a0 '{\"ttl\":1,\"text\":\"dnsaddr=/dnsaddr/'$MOD'.'$DOMAIN'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}${MOD}/_dnsaddr/a0 '{\"ttl\":1,\"text\":\"dnsaddr=/dnsaddr/bee-0.'$DOMAIN'\"}' --user=root --password=secret" &> /dev/null
    # kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}${MOD}/_dnsaddr/b0 '{\"ttl\":1,\"text\":\"dnsaddr=/dnsaddr/bee-0.'$DOMAIN'/udp/1634/p2p/quic/'$BEE_0_HASH'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}bee-0/_dnsaddr/a0 '{\"ttl\":1,\"text\":\"dnsaddr=/ip4/'$ip'/tcp/1634/p2p/'$BEE_0_HASH'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}bee-0/_dnsaddr/b0 '{\"ttl\":1,\"text\":\"dnsaddr=/ip4/'$ip'/udp/1634/p2p/quic/'$BEE_0_HASH'\"}' --user=root --password=secret" &> /dev/null
}

# after every pod is started get all values and populate dns
_populate_dns() {
    i="${1}"
    SKYDNS=$(_revdomain ${DOMAIN/./ })
    # shellcheck disable=SC1117,SC2059
    MOD=$(printf "\x6$((i % 4 + 1))")
    UNDERLAY_TCP=$(curl -s bee-"${i}"-debug.${DOMAIN}/addresses | jq -r '.underlay | .[] | [match("\/ip4\/(192.168|10.|172.1[6789].|172.2[0-9].|172.3[01].).*\/tcp\/\\d{1,5}\/p2p\/[a-zA-Z0-9]*")] | .[] | .string')
    UNDERLAY_UDP=$(curl -s bee-"${i}"-debug.${DOMAIN}/addresses | jq -r '.underlay | .[] | [match("\/ip4\/(192.168|10.|172.1[6789].|172.2[0-9].|172.3[01].).*\/udp\/\\d{1,5}\/quic\/p2p\/[a-zA-Z0-9]*")] | .[] | .string')
    IFS=/ read -r _ _ ip lay4 port prot hash <<< "${UNDERLAY_TCP}"
    IFS=/ read -r _ _ _ lay4_u _ prot1_u prot2_u _ <<< "${UNDERLAY_UDP}"
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}_dnsaddr/a${i} '{\"ttl\":1,\"text\":\"dnsaddr=/dnsaddr/'$MOD'.'$DOMAIN'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}${MOD}/_dnsaddr/a${i} '{\"ttl\":1,\"text\":\"dnsaddr=/dnsaddr/bee-'$i'.'$DOMAIN'\"}' --user=root --password=secret" &> /dev/null
    # kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}${MOD}/_dnsaddr/b${i} '{\"ttl\":1,\"text\":\"dnsaddr=/dnsaddr/bee-'$i'.'$DOMAIN'/'$lay4_u'/'$port'/'$prot1_u'/'$prot2_u'/'$hash'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}bee-${i}/_dnsaddr/a${i} '{\"ttl\":1,\"text\":\"dnsaddr=/ip4/'$ip'/'$lay4'/'$port'/'$prot'/'$hash'\"}' --user=root --password=secret" &> /dev/null
    kubectl exec -ti etcd-0 -n etcd -- sh -c "ETCDCTL_API=3 etcdctl put /skydns/${SKYDNS}bee-${i}/_dnsaddr/b${i} '{\"ttl\":1,\"text\":\"dnsaddr=/ip4/'$ip'/'$lay4_u'/'$port'/'$prot1_u'/'$prot2_u'/'$hash'\"}' --user=root --password=secret" &> /dev/null
}

_helm() {
    if [[ -n $DNS_DISCO ]]; then
        _clear_dns
    fi
    LAST_BEE=$((REPLICA-1))
    PAY_TOLERANCE=$((PAY_THRESHOLD/10))
    PAY_EARLY=$((PAY_THRESHOLD/10))
    if [[ $ACTION == "upgrade" ]]; then
        BEES=$(seq $LAST_BEE -1 0)
    else
        BEES=$(seq 0 1 $LAST_BEE)
    fi
    if [ "${CLEF}" == "true" ]; then
        helm "${1}" bee -f helm-values/bee.yaml "${CHART}" --namespace "${NAMESPACE}" --set beeConfig.bootnode="${HELM_SET_BOOTNODES}" --set image.repository="${HELM_SET_REPO}" --set image.tag="${IMAGE_TAG}" --set replicaCount="${REPLICA}" --set beeConfig.cache_capacity="${CACHE_CAPACITY}" --set beeConfig.payment_threshold="${PAY_THRESHOLD}" --set beeConfig.payment_tolerance="${PAY_TOLERANCE}" --set beeConfig.payment_early="${PAY_EARLY}" --set beeConfig.swap_enable="${GETH}" --set beeConfig.clef_signer_enable="true"  --set clefSettings.enabled="true" ${POSTAGE} &> /dev/null
    else
        helm "${1}" bee -f helm-values/bee.yaml "${CHART}" --namespace "${NAMESPACE}" --set beeConfig.bootnode="${HELM_SET_BOOTNODES}" --set image.repository="${HELM_SET_REPO}" --set image.tag="${IMAGE_TAG}" --set replicaCount="${REPLICA}" --set beeConfig.cache_capacity="${CACHE_CAPACITY}" --set beeConfig.payment_threshold="${PAY_THRESHOLD}" --set beeConfig.payment_tolerance="${PAY_TOLERANCE}" --set beeConfig.payment_early="${PAY_EARLY}" --set beeConfig.swap_enable="${GETH}" ${POSTAGE} &> /dev/null
    fi
    for i in ${BEES}; do
        echo "waiting for the bee-${i}..."
        if [[ -n $DNS_DISCO ]] && [[ $i -eq 0 ]]; then
            until kubectl get pod --namespace "${NAMESPACE}" bee-0 &> /dev/null; do echo "waiting for the bee-0..."; sleep 1; done
            until [[ "$(kubectl get pod --namespace "${NAMESPACE}" bee-0 -o json | jq -r .status.podIP 2> /dev/null)" != "null" ]]; do echo "waiting for the bee-0..."; sleep 1; done
            BEE_0_IP=$(kubectl get pod --namespace "${NAMESPACE}" bee-0 -o json | jq -r .status.podIP)
            _populate_dns_0 "${BEE_0_IP}"
        else
            until [[ "$(curl -s bee-"${i}"-debug."${DOMAIN}"/readiness | jq -r .status 2>/dev/null)" == "ok" ]]; do
                sleep .3
            done
            if [[ -n $DNS_DISCO ]]; then
                _populate_dns "${i}"
            fi
        fi
        until [[ "$(curl -s bee-"${i}"-debug.${DOMAIN}/peers | jq -r '.peers | length' 2> /dev/null)" -eq ${LAST_BEE} ]]; do sleep 1; done
    done
}

_helm_template() {
    if [[ -n $DNS_DISCO ]]; then
        _clear_dns
    fi
    LAST_BEE=$((REPLICA-1))
    if [[ $ACTION == "upgrade" ]]; then
        BEES=$(seq $LAST_BEE -1 0)
    else
        BEES=$(seq 0 1 $LAST_BEE)
    fi
    helm template bee -f helm-values/bee.yaml "${CHART}" --namespace "${NAMESPACE}" --set beeConfig.bootnode="${HELM_SET_BOOTNODES}" --set image.repository="${HELM_SET_REPO}" --set image.tag="${IMAGE_TAG}" --set replicaCount="${REPLICA}" --no-hooks > bee-parallel.yaml
    f=bee-parallel.yaml
    yq w -i -d$(awk '$0 == "---" { d++ } /^kind:/ { kind = $2 } /^  name: bee$/ { if (kind == "StatefulSet") exit } END { print d-1 }' "$f") "$f" spec.podManagementPolicy Parallel &> /dev/null
    kubectl create -f bee-parallel.yaml -n "${NAMESPACE}" &> /dev/null
    for i in ${BEES}; do
        echo "waiting for the bee-${i}..."
        if [[ -n $DNS_DISCO ]] && [[ $i -eq 0 ]]; then
            until kubectl get pod --namespace "${NAMESPACE}" bee-0 &> /dev/null; do echo "waiting for the bee-0..."; sleep 1; done
            until [[ "$(kubectl get pod --namespace "${NAMESPACE}" bee-0 -o json | jq -r .status.podIP 2> /dev/null)" != "null" ]]; do echo "waiting for the bee-0..."; sleep 1; done
            BEE_0_IP=$(kubectl get pod --namespace "${NAMESPACE}" bee-0 -o json | jq -r .status.podIP)
            _populate_dns_0 "${BEE_0_IP}"
        else
            until [[ "$(curl -s bee-"${i}"-debug."${DOMAIN}"/readiness | jq -r .status 2>/dev/null)" == "ok" ]]; do
                sleep .3
            done
            if [[ -n $DNS_DISCO ]]; then
                _populate_dns "${i}"
            fi
        fi
        until [[ "$(curl -s bee-0-debug.${DOMAIN}/peers | jq -r '.peers | length' 2> /dev/null)" -eq ${LAST_BEE} ]]; do sleep 1; done
    done
}

_helm_uninstall() {
    helm uninstall bee -n "${NAMESPACE}" &> /dev/null
    helm uninstall geth-swap -n geth &> /dev/null
    echo "uninstalling bee and geth ns.."
}

_helm_uninstall_template() {
    kubectl delete -f bee-parallel.yaml -n "${NAMESPACE}" &> /dev/null

    if [[ -n $DNS_DISCO ]]; then
        _clear_dns
    fi
    echo "uninstalling bee pods.."
}

_helm_on_delete() {
    if [[ -n $DNS_DISCO ]]; then
        _clear_dns
    fi
    helm upgrade bee -f helm-values/bee.yaml "${CHART}" --namespace "${NAMESPACE}" --set image.repository="${HELM_SET_REPO}" --set image.tag="${IMAGE_TAG}" --set replicaCount="${REPLICA}" &> /dev/null
    for ((i=0; i<REPLICA; i++)); do
        kubectl delete pod --namespace "${NAMESPACE}" bee-"${i}" &> /dev/null
        echo "waiting for the bee-${i}..."
        until [[ "$(curl -s bee-"${i}"-debug."${DOMAIN}"/readiness | jq -r .status 2>/dev/null)" == "ok" ]]; do
            sleep .1
        done
        if [[ -n $DNS_DISCO ]]; then
            _populate_dns "${i}"
        fi
        sleep 2
    done
}

_helm_upgrade_check() {
    if ! helm get values bee -n "${NAMESPACE}" -o json &> /dev/null; then
        echo "no release, use install..."
        exit 1
    fi
    STRATEGY=$(helm get values bee -n "${NAMESPACE}" -o json | jq -r .updateStrategy.type)
    if [[ $STRATEGY == "OnDelete" ]]; then
        _helm_on_delete
    else
        _helm upgrade
    fi
}

_dns_disco() {
    kubectl get configmaps --namespace=kube-system coredns -o yaml | sed "s/reload$/reload 2s/" | kubectl apply -f - &> /dev/null
    kubectl create ns etcd &> /dev/null
    helm repo add bitnami https://charts.bitnami.com/bitnami &> /dev/null
    helm repo update &> /dev/null
    helm install etcd bitnami/etcd --namespace=etcd -f helm-values/etcd.yaml &> /dev/null
    until kubectl get svc etcd -n etcd &> /dev/null; do echo "waiting for the etcd..."; sleep 1; done
    until kubectl exec -ti etcd-0 -n etcd -- sh -c "curl http://127.0.0.1:2379/version" &> /dev/null; do echo "waiting for the etcd..."; sleep 1; done
    ETCD_IP=$(kubectl get svc etcd -n etcd -o=custom-columns=IP:.spec.clusterIP --no-headers)
    ## Configure cluster coredns to query etcd for custom domain
    kubectl get configmaps --namespace=kube-system coredns -o yaml | sed -e '/  Corefile: |/{r hack/Customfile' -e 'd' -e '}' | sed "s/{ETCD_IP}/${ETCD_IP}/; s/{DOMAIN}/${DOMAIN}/" | kubectl apply -f - &> /dev/null
    kubectl delete pod --namespace kube-system -l k8s-app=kube-dns &> /dev/null
    until [[ $(kubectl get pod --namespace kube-system -l k8s-app=kube-dns -o json | jq .items[0].status.containerStatuses[0].ready 2>/dev/null) == "true" ]]; do echo "waiting for the coredns..."; sleep 1; done
    echo "installed dns discovery support..."
}

_chaos() {
    echo "installing chaos-mesh..."
    if [ ! -d "chaos-mesh" ]; then
        git clone https://github.com/pingcap/chaos-mesh.git &> /dev/null
    fi
    cd chaos-mesh &> /dev/null
    echo "apply crds for chaos-mesh..."
    kubectl apply -f manifests/crd.yaml &> /dev/null
    kubectl create ns chaos-testing &> /dev/null
    echo "install chaos-mesh operator..."
    helm install chaos-mesh helm/chaos-mesh --namespace=chaos-testing --set chaosDaemon.runtime=containerd --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock &> /dev/null
    echo "installed chaos-mesh..."
    cd .. &> /dev/null
}

_geth() {
    echo "installing geth..."
    kubectl create ns geth &> /dev/null || true
    helm install geth-swap ethersphere/geth-swap -n geth -f helm-values/geth-swap.yaml &> /dev/null
    until [[ $(kubectl get pod --namespace geth -l job-name=geth-swap-setupcontracts -o json | jq -r '.items|last|.status.containerStatuses[0].state.terminated.reason' 2>/dev/null) == "Completed" ]]; do echo "waiting for the geth init..."; sleep 1; done
    echo "installed geth..."
}

_test() {
    _check_beekeeper
    echo "executing beekeeper tests..."
    sleep 5
    echo "fullconnectivity"
    ./beekeeper check fullconnectivity --api-scheme http --debug-api-scheme http --disable-namespace --debug-api-domain "${DOMAIN}" --api-domain "${DOMAIN}" --node-count "${REPLICA}"
    echo "pingpong"
    ./beekeeper check pingpong --api-scheme http --debug-api-scheme http --disable-namespace --debug-api-domain "${DOMAIN}" --api-domain "${DOMAIN}" --node-count "${REPLICA}"
    echo "pushsync (bytes)"
    ./beekeeper check pushsync --api-scheme http --debug-api-scheme http --disable-namespace --debug-api-domain "${DOMAIN}" --api-domain "${DOMAIN}" --node-count "${REPLICA}" --upload-node-count "${REPLICA}" --chunks-per-node 3
    echo "pushsync (chunks)"
    ./beekeeper check pushsync --api-scheme http --debug-api-scheme http --disable-namespace --debug-api-domain "${DOMAIN}" --api-domain "${DOMAIN}" --node-count "${REPLICA}" --upload-node-count "${REPLICA}" --chunks-per-node 3 --upload-chunks
    echo "retrieval"
    ./beekeeper check retrieval --api-scheme http --debug-api-scheme http --disable-namespace --debug-api-domain "${DOMAIN}" --api-domain "${DOMAIN}" --node-count "${REPLICA}" --upload-node-count "${REPLICA}" --chunks-per-node 3
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    while [[ $# -gt 0 ]]; do
        key="$1"

        case "${key}" in
#/   install    helm install bee
            install)
                ACTION="install"
                shift
            ;;
#/   install-template    install bee from template
            install-template)
                ACTION="install-template"
                shift
            ;;
#/   prepare    prepare cluster infra
            prepare)
                ACTION="prepare"
                shift
            ;;
#/   upgrade    helm upgrade bee
            upgrade)
                ACTION="upgrade"
                shift
            ;;
#/   uninstall  helm uninstall bee
            uninstall)
                ACTION="uninstall"
                shift
            ;;
#/   uninstall-template  helm uninstall-template bee
            uninstall-template)
                ACTION="uninstall-template"
                shift
            ;;
#/   build      build local image and push to local registry
            build)
                ACTION="build"
                shift
            ;;
#/   test       run only tests
            test)
                ACTION="test"
                shift
            ;;
# chaos will install chaos-mesh https://github.com/pingcap/chaos-mesh
#/   chaos      install chaos-mesh
            chaos)
                ACTION="chaos"
                shift
            ;;
#/   geth       install geth-swap in cluster
            geth)
                ACTION="geth"
                shift
            ;;
#/   dns-disco   prepare cluster for dns discovery
            dns-disco)
                ACTION="dns-disco"
                shift
            ;;
#/   destroy    destroy k3d cluster
            destroy)
                DESTROY="true"
                ACTION="destroy"
                shift
            ;;
#/
#/ Options:
#/   -d, --domain fqdn  set domain (default is localhost)
            -d|--domain)
                DOMAIN="${2}"
                shift 2
            ;;
#/   -r, --replica n    set number of bee replicas (default is 3)
            -r|--replica)
                REPLICA="${2}"
                shift 2
            ;;
#/   --bootnode         set bootnode (default is predifined bee-0 multiaddress)
            --bootnode)
                HELM_SET_BOOTNODES="${2}"
                shift 2
            ;;
#/   --test             run beekeeper tests at the end (default is false)
            --test)
                RUN_TESTS="true"
                shift
            ;;
#/   --chaos            run beekeeper chaoss at the end (default is false)
            --chaos)
                CHAOS="true"
                shift
            ;;
#/   --geth             install geth-swap in cluster (default is false)
            --geth)
                GETH="true"
                shift
            ;;
#/   --clef             install clef enabled bee (default is false)
            --clef)
                CLEF="true"
                shift
            ;;
#/   --dns-disco        enable dns-discovery infra for bee (default is false)
            --dns-disco)
                DNS_DISCO="true"
                shift
            ;;
#/   --pay-threshold    set pay threshold, pay tolerance will be 10% from this value
            --pay-threshold)
                PAY_THRESHOLD="${2}"
                shift 2
            ;;
#/   --db-capacity      set db capacity, default 2000
            --db-capacity)
                CACHE_CAPACITY="${2}"
                shift 2
            ;;
#/   --local            use local bee code, build it and deploy it (default is false)
            --local)
                HELM_SET_REPO="${REGISTRY}"/"${REPO}"
                LOCAL="true"
                shift
            ;;
#/   --k3s             use k3s for local cluster (default is k3d)
            --k3s)
                K3S="true"
                shift
            ;;
#/   --postage         set postage-stamp-address to 0x538e6de1d876bbcd5667085257bc92f7c808a0f3 and 
#/                     price-oracle-address to 0xfc28330f1ece0ef2371b724e0d19c1ee60b728b2
            --postage)
                POSTAGE="--set beeConfig.postage_stamp_address=0x538e6de1d876bbcd5667085257bc92f7c808a0f3 --set beeConfig.price_oracle_address=0xfc28330f1ece0ef2371b724e0d19c1ee60b728b2"
                shift
            ;;
#/   -h, --help         display this help message
            *)
                usage
            ;;
        esac
    done

    if [[ -z $ACTION ]]; then
        usage
    fi

    if [[ $ACTION == "test" ]]; then
        _test
        exit 0
    fi

    if [[ -n $DESTROY ]]; then
        if [[ -n $K3S ]]; then
            echo "destroying k3s cluster..."
            docker rm -f registry.localhost &> /dev/null
            /usr/local/bin/k3s-uninstall.sh &> /dev/null
        else
            echo "destroying k3d cluster..."
            docker network disconnect k3d-k3s-default registry.localhost &> /dev/null
            docker rm -f registry.localhost &> /dev/null
            k3d d &> /dev/null
        fi
        exit 0
    fi
    
    if [[ $ACTION == "uninstall" ]]; then
        _helm_uninstall
        exit 0
    elif [[ $ACTION == "uninstall-template" ]]; then
        _helm_uninstall_template
        exit 0
    fi

    _check_deps

    if [[ $ACTION == "prepare" ]]; then
        _prepare
        exit 0
    fi

    if [[ $ACTION == "chaos" ]]; then
        _chaos
        exit 0
    fi

    if [[ $ACTION == "dns-disco" ]]; then
        _dns_disco
        exit 0
    fi

    if [[ $ACTION == "geth" ]]; then
        _geth
        exit 0
    fi

    if [[ -n $LOCAL ]] && [[ $ACTION == "build" ]]; then
        _build
        exit 0
    fi

    if k3d ls &> /dev/null; then
        echo "k3d cluster running..."
    elif [[ $(k3d ls 2>/dev/null| grep k3s | cut -d' ' -f6) == "stopped" ]]; then
        k3d start &> /dev/null
    elif [[ -n $K3S ]]; then 
        if sudo systemctl is-active k3s &> /dev/null; then
            echo "k3s cluster running..."
        fi
    else
        _prepare
    fi

    if [[ -n $LOCAL ]] && [[ ! $ACTION == "uninstall" ]]; then
        _build
    fi

    if [[ $ACTION == "upgrade" ]]; then
        _helm_upgrade_check
    elif [[ $ACTION == "install-template" ]]; then
        _helm_template
    else
        _helm "${ACTION}"
    fi

    if [[ -n $RUN_TESTS ]] && [[ ! $ACTION == "uninstall" ]]; then
        _test
    fi
fi
