# Linuxboot CI

Linuxboot CI is a continuous integration platform dedicated to build and test Linuxboot firmware. This
repository contains deployment automation tools for Linuxboot CI platform.

## Prerequisites

In order to deploy Linuxboot CI you need at leat two machines on a single subnet. First machine will be the controller node and the other one will be the compute node (job runner).

__Note.__
 > Currently, deployment works only on debian based distributions and is tested on Ubuntu 16.04 only.

Controller node can be either a bare matal server or a virtual machine, but compute nodes should be bare metal servers because it uses virtualization to sandbox jobs.

Additionnaly, you need a deployer host to orchestrate Linuxboot CI deployment. This host can be any machine with
[Ansible](https://www.ansible.com/) installed (at least version 2.4). This host must be able to reach the controller node using SSH.

Also:

* Controller and Compute hosts must have a sudoer account without password
* Controller and Compute hosts must be SSH accessible without password from Deployer host

__Sample infrastructure__

```
  |-----------------|                       |-----------------|
  |   Controller    |                       |     Compute     |
  |-----------------|                       |-----------------|
          | 10.0.3.2                                 | 10.0.3.4
          |                                          |
----------------------------------------------------------------- 10.0.3.0/24
          |
          | 10.0.3.100
  |-----------------|
  |    Deployer     |
  |-----------------|
```

## Prepare your configuration

Clone this repository on the Deployer host and edit configuration files in `inventory` folders:

* Hosts usernames
* Hosts IP addresses

In the default configuration, the Controller node is a DHCP serveur for compute nodes. If you already have a DHCP server on your network or if you setted up static addressing, you can disable it using the variable `dhcp["enabled"]`.

## Run deployment

Once configuration is setted up for your environment, you are good to go. On the Deployer, from the root of this
repository tree, run

```
$ ansible-playbook -i inventory/hosts linuxboot-ci.yml
```

When command is done, the platform is up and running.

## Run you first job

It's time to run you first job. You need a git repository containing a CI descriptor `.ci.yml`. The sample repository [linuxboot/linuxboot-ci-test](https://github.com/linuxboot/linuxboot-ci-test) is used to perform
some tests. Each single branch in this repos is a different test case.

Interraction with the CI platform is achived using a REST API. API specification can be found in
[linuxboot/linuxboot-ci-api](https://github.com/linuxboot/linuxboot-ci-api).

__Example__

Submit a job using `curl` client

```
curl -i -X POST "http://<controler>:1234/v1/jobs" -H "X-Auth-Secret: ..." -d '
{
    "repository": {
            "url": "https://github.com/linuxboot/linuxboot-ci-test.git"
    }
}
'
```

## Platform Architecture

__To Do__
 > Global architecture involving should be described here
