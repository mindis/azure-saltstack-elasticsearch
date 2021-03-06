#!/bin/bash

echo $(date +"%F %T%z") "starting script saltstackinstall.sh"

# arguments
adminUsername=$1
adminPassword=$2
subscriptionId=$3
storageName=$4
vnetName=$5
location=$6
resourceGroupname=$7
subnetName=$8
clientid=$9
secret=${10}
tenantid=${11}
publicip=${12}
nsgname=${13}

echo "----------------------------------"
echo "INSTALLING SALT"
echo "----------------------------------"

curl -s -o $HOME/bootstrap_salt.sh -L https://bootstrap.saltstack.com
sh $HOME/bootstrap_salt.sh -M -p python2-boto git 5b1af94

# latest commit from develop branch
sh $HOME/bootstrap_salt.sh -M -p python2-boto git 54ed167
#sh $HOME/bootstrap_salt.sh -M -g https://github.com/ritazh/salt-1.git git azurearm

easy_install-2.7 pip==7.1.0
yum install -y gcc gcc-c++ git make libffi-devel openssl-devel python-devel
curl -s -o $HOME/requirements.txt -L https://raw.githubusercontent.com/ritazh/azure-saltstack-elasticsearch/master/requirements.txt
pip install -r $HOME/requirements.txt

cd /etc/salt
myip=$(hostname --ip-address)
echo "interface: $myip" >> master
echo "hash_type: sha256" >> master
echo "file_roots:
  base:
    - /srv/salt" >> master

systemctl start salt-master.service
systemctl enable salt-master.service
salt-cloud -u

echo "----------------------------------"
echo "CONFIGURING SALT-CLOUD"
echo "----------------------------------"

mkdir cloud.providers.d && cd cloud.providers.d
echo "azure:
  driver: azurearm
  subscription_id: $subscriptionId
  client_id: $clientid
  secret: $secret
  tenant: $tenantid
  minion:
    master: $publicip
    hash_type: sha256
    tcp_keepalive: True
    tcp_keepalive_idle: 180
  grains:
    home: /home/$adminUsername
    provider: azure
    user: $adminUsername" > azure.conf
cd ..
mkdir cloud.profiles.d && cd cloud.profiles.d

echo "azure-vm:
  provider: azure
  image: OpenLogic|CentOS|7.2n|7.2.20160629
  size: Standard_DS2_v2
  location: $location
  ssh_username: $adminUsername
  ssh_password: $adminPassword
  storage_account: $storageName
  resource_group: $resourceGroupname
  security_group: $nsgname
  network_resource_group: $resourceGroupname
  network: $vnetName
  subnet: $subnetName
  public_ip: True
  script: bootstrap-salt.sh
  script_args: -U
  sync_after_install: grains

azure-vm-esnode:
  extends: azure-vm
  size: Standard_DS2_v2
  volumes:
    - {disk_size_gb: 50, name: 'datadisk1' }
  minion:
    grains:
      region: $location
      roles: elasticsearch
      elasticsearch:
        cluster: es-cluster-local-01

azure-vm-esmaster:
  extends: azure-vm
  size: Standard_DS2_v2
  volumes:
    - {disk_size_gb: 50, name: 'datadisk1' }
  minion:
    grains:
      region: $location
      roles: elasticsearchmaster
      elasticsearchmaster:
        cluster: es-cluster-local-01

azure-ubuntu:
  provider: azure
  image: Canonical|UbuntuServer|14.04.5-LTS|14.04.201612050
  size: Standard_DS2_v2
  location: $location
  ssh_username: $adminUsername
  ssh_password: $adminPassword
  resource_group: $resourceGroupname
  network_resource_group: $resourceGroupname
  network: $vnetName
  subnet: $subnetName
  public_ip: True
  storage_account: $storageName

azure-mysql:
  extends: azure-ubuntu
  minion:
    grains:
      region: eastus
      roles: mysql"> azure.conf

echo "----------------------------------"
echo "RUNNING SALT-CLOUD"
echo "----------------------------------"

salt-cloud -p azure-vm-esmaster "${resourceGroupname}minionesmaster"
salt-cloud -p azure-vm-esnode "${resourceGroupname}minionesnode"

echo "----------------------------------"
echo "CONFIGURING ELASTICSEARCH"
echo "----------------------------------"

cd /srv/
mkdir salt && cd salt
echo "base:
  '*':
    - common_packages
  'roles:elasticsearch':
    - match: grain
    - elasticsearch
  'roles:elasticsearchmaster':
    - match: grain
    - elasticsearchmaster
  'roles:mysql':
    - match: grain
    - mysql" > top.sls

echo "common_packages:
    pkg.installed:
        - names:
            - git
            - tmux
            - tree" > common_packages.sls

mkdir elasticsearchmaster && cd elasticsearchmaster
wget http://packages.elasticsearch.org/GPG-KEY-elasticsearch -O GPG-KEY-elasticsearch

echo "# Elasticsearch configuration for {{ grains['fqdn'] }}
# Cluster: {{ grains[grains['roles']]['cluster'] }}

cluster.name: {{ grains[grains['roles']]['cluster'] }}
node.name: '{{ grains['fqdn'] }}'
node.master: true
node.data: false
discovery.zen.ping.multicast.enabled: false
discovery.zen.ping.unicast.hosts: ['{{ grains['fqdn'] }}']" > elasticsearch.yml

cookie="'Cookie: oraclelicense=accept-securebackup-cookie'"

echo "Download Oracle JDK:
    cmd.run:
        - name: \"wget --no-check-certificate --no-cookies --header $cookie http://download.oracle.com/otn-pub/java/jdk/8u101-b13/jdk-8u101-linux-x64.rpm\"
        - cwd: /home/$adminUsername/
        - runas: root
        - onlyif: if [ -f /home/$adminUsername/jdk-8u101-linux-x64.rpm ]; then exit 1; else exit 0; fi;

Install Oracle JDK:
    cmd.run:
        - name: yum install -y /home/$adminUsername/jdk-8u101-linux-x64.rpm
        - onlyif: if yum list installed jdk-8u101 >/dev/null 2>&1; then exit 1; else exit 0; fi;

elasticsearch_repo:
    pkgrepo.managed:
        - humanname: Elasticsearch Official Centos Repository
        - name: elasticsearch
        - baseurl: https://packages.elastic.co/elasticsearch/1.7/centos
        - gpgkey: https://packages.elastic.co/GPG-KEY-elasticsearch
        - gpgcheck: 1

elasticsearch:
    pkg:
        - installed
        - require:
            - pkgrepo: elasticsearch_repo

    service:
        - running
        - enable: True
        - require:
            - pkg: elasticsearch
            - file: /etc/elasticsearch/elasticsearch.yml

/etc/elasticsearch/elasticsearch.yml:
  file:
    - managed
    - user: root
    - group: root
    - mode: 644
    - template: jinja
    - source: salt://elasticsearchmaster/elasticsearch.yml" > init.sls

cd ..

mkdir elasticsearch && cd elasticsearch
wget http://packages.elasticsearch.org/GPG-KEY-elasticsearch -O GPG-KEY-elasticsearch

echo "# Elasticsearch configuration for {{ grains['fqdn'] }}
# Cluster: {{ grains[grains['roles']]['cluster'] }}

cluster.name: {{ grains[grains['roles']]['cluster'] }}
node.name: '{{ grains['fqdn'] }}'
node.master: false
node.data: true
discovery.zen.ping.multicast.enabled: false
discovery.zen.ping.unicast.hosts: ['${resourceGroupname}minionesmaster']" > elasticsearch.yml

echo "Download Oracle JDK:
    cmd.run:
        - name: \"wget --no-check-certificate --no-cookies --header $cookie http://download.oracle.com/otn-pub/java/jdk/8u101-b13/jdk-8u101-linux-x64.rpm\"
        - cwd: /home/$adminUsername/
        - runas: root
        - onlyif: if [ -f /home/$adminUsername/jdk-8u101-linux-x64.rpm ]; then exit 1; else exit 0; fi;

Install Oracle JDK:
    cmd.run:
        - name: yum install -y /home/$adminUsername/jdk-8u101-linux-x64.rpm
        - onlyif: if yum list installed jdk-8u101 >/dev/null 2>&1; then exit 1; else exit 0; fi;

elasticsearch_repo:
    pkgrepo.managed:
        - humanname: Elasticsearch Official Centos Repository
        - name: elasticsearch
        - baseurl: https://packages.elastic.co/elasticsearch/1.7/centos
        - gpgkey: https://packages.elastic.co/GPG-KEY-elasticsearch
        - gpgcheck: 1

elasticsearch:
    pkg:
        - installed
        - require:
            - pkgrepo: elasticsearch_repo

    service:
        - running
        - enable: True
        - require:
            - pkg: elasticsearch
            - file: /etc/elasticsearch/elasticsearch.yml

/etc/elasticsearch/elasticsearch.yml:
  file:
    - managed
    - user: root
    - group: root
    - mode: 644
    - template: jinja
    - source: salt://elasticsearch/elasticsearch.yml" > init.sls

cd ..
echo "----------------------------------"
echo "INSTALLING ELASTICSEARCH"
echo "----------------------------------"

# salt-call --local service.restart salt-minion
#salt '*' saltutil.refresh_pillar

salt -G 'roles:elasticsearchmaster' state.highstate
salt -G 'roles:elasticsearch' state.highstate

# echo "----------------------------------"
# echo "ADD CONFIGURATIONS FOR MYSQL"
# echo "----------------------------------"
# mkdir -p /srv/pillar
# cd /srv/pillar

# echo "base:
#   'roles:mysql':
#     - match: grain
#     - mysql" > top.sls

# echo "mysql:
#   server:
#     root_password: 'devitconf'
#   database:
#     - devitconf" > mysql.sls

#cd /srv/salt
#git clone https://github.com/saltstack-formulas/mysql-formula.git

#echo "    - /srv/salt/mysql-formula" >> /etc/salt/master

#systemctl restart salt-master.service

# echo "----------------------------------"
# echo "CREATING NODES FOR MYSQL"
# echo "----------------------------------"
#salt-cloud -p azure-mysql "${resourceGroupname}minionmysql0"

# echo "----------------------------------"
# echo "INSTALLING MYSQL"
# echo "----------------------------------"
#salt -G 'roles:mysql' state.highstate

echo $(date +"%F %T%z") "ending script saltstackinstall.sh"
