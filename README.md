# Bee local cluster development

This repository contains all the definitions for the Bee local cluster development used by the Swarm Team.

## Prerequisites

* [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/) >= 1.15
* [helm](https://helm.sh/docs/intro/install/) >= 3.0
* [jq](https://stedolan.github.io/jq/download/) >= 1.15
* resolvable `.localhost` domain to 127.0.0.1
    * enabled by default on Linux
    * [how to configure on MacOS](DNS.md)

## Installing

Clone this repo and run:

```bash
./beeinfra.sh install --test --local -r 3
```

* it will install [k3d](https://k3d.io/) and configure local k8s cluster
* build and unit test local `bee` repo (`--local`)
* install 3 bee replicas on cluster (`-r 3`)
* and execute all integration test (`--test`)

## Usage

Use `./beeinfra.sh -h` for more options

## Bee cluster bootstrap

By default `bee-0` will have a fixed hash and other nodes will connect using known multiaddr for `bee-0`.

For DNS discovery inside [helm-values/bee.yaml](helm-values/bee.yaml) set `bootnode.enabled` to `false` and uncomment `bootnode` under `beeConfig` and install cluster using command
```bash
./beeinfra.sh install --dns-disco --local --test -r 3
```
