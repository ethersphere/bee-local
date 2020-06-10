## Configure DNS resolver

To be able to access `bee` cluster from the local machine, needed for tests and debug, we need to install `dnsmasq` and configure it to resolve whole `.locahost` domain as `127.0.0.1`

### Installation

* install dnsmasq
>```bash
>brew install dnsmasq
>```

* configure dns to resolve .localhost domain to 127.0.0.1
>```bash
>echo "" >> $(brew --prefix)/etc/dnsmasq.conf
>echo "# Local development server (custom setting)" >> $(brew --prefix)/etc/dnsmasq.conf
>echo 'address=/.localhost/127.0.0.1' >> $(brew --prefix)/etc/dnsmasq.conf
>echo 'port=53' >> $(brew --prefix)/etc/dnsmasq.conf
>```

* start dnsmasq as a long running service
>```bash
>sudo brew services start dnsmasq
>```

* configure system that for .localhost domain query dnsmasq
>```bash
>sudo mkdir -pv /etc/resolver
>sudo bash -c 'echo "nameserver 127.0.0.1" > /etc/resolver/localhost'
>```

Confirm that installation was successful with:

`nslookup example.localhost`

## <a id="hosts"></a>Populate /etc/hosts

* add entries (set REPLICA)
>```bash
>export REPLICA=3
>echo -e "127.0.0.10\tregistry.localhost" | sudo tee -a /etc/hosts
>for ((i=0; i<REPLICA; i++)); do echo -e "127.0.1.$((i+1))\tbee-${i}.localhost bee-${i}-debug.localhost"; done | sudo tee -a /etc/hosts
>```
* remove entries
>```bash
>grep -vE 'bee|registry.localhost' /etc/hosts | sudo tee /etc/hosts
>```