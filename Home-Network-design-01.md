# Setup my home network

Devices: GL.iNet GL-BE6500
Software: OpenWrt 23.05-SNAPSHOT

A4ET5F2KZP

```prompt
Let's restart. This router has the Loadbalancing capabilities. So, I would like to keep it working. 
However, I would like the Gaming PC to only use the Digi connection because of the low latency using a direct connection to PPPoE that is already setup.  
The other devices should be in a different VLAN that uses Vodafone and only use Digi if Vodafone is down. 
```

## First, I want to have a VLAN-1 for my Gaming PC

This is only for my Gaming PC, and it will use the first ISP Digi as the primary connection, and the second ISP Vodafone as the secondary connection in case Digi is down.

## Second, I want to have a VLAN-2 for my Home Server

Because, in the Home Lab server, I have a Plex Server that has the Smart TV as a client, the Smart Phones are also clients of the Plex Server, and the Tablets are also clients of the Plex Server, I want to have a VLAN-2 for all these devices, and it will use the second ISP Vodafone as the primary connection, and the first ISP Digi as the secondary connection in case Vodafone is down.

- Home Lab Server
  - Plex Server
  - Kubernetes Cluster with 3 VMs, one Master and two Workers, to learn Kubernetes and to run some services in the cluster.
  - Cloudflare Tunnel to expose my App to the internet
  - Qtorrent Server to download movies and TV shows for the Plex Server
- Smart TV
- Smart Phones
- Tablets
- iWatch

## Third, I want to have a VLAN-3 for my IoT devices

VLAN-3 will be the default VLAN for all my devices, and it will use the second ISP Vodafone as the primary connection, and the first ISP Digi as the secondary connection in case Vodafone is down.

- Smart Electric Plugs
- Smart Lamps
- Amazon Kindle
- Cat's Feeder
- Cat's Bathroom
- Cameras
- Amazon Alexa

## The guest WIFI

The guest WIFI should be added to a different VLAN that uses only the second ISP Vodafone.

## Future plans

- I want to define the Network Name of each device in the router, so I can easily identify them in the network map and manage them better.
- I want to know how to read the firewall rules in OpenWrt, so I can manage the access between the VLANs and to the internet.
- I want to have a backup strategy for my router configuration, so I can easily restore it
- I want to have a monitoring strategy for my network, so I can easily identify any issues or bottlenecks in the network.
- I want to have a strategy for updating the firmware of my router, so I can keep it secure and up to date without risking bricking the device.
- I want to have a strategy for managing the devices in my network, so I can easily identify and manage them, and also have a strategy for adding new devices to the network in the future.
- I want to be able to access my home network remotely, so I can manage it and access my devices from anywhere in the world securely.

## First Prompt to Claude Sonnet 4.6

```text
/create-agent read the Home-Network-design-01.md and create a second file with the steps that I can achieve what I need called Home-Network-Step-by-Step.md. This file needs to have the explanation and why of each step. The configuration needs to be done step by step, followed via system backup to avoid bricking the device. 
```
