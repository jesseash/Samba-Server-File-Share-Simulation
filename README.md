
In this release what we're after is far from perfection but reporoducibilty. At the end of the day if we can get the same exact result on everyones machine good or bad then abstractions be dammed we will have accomplished something. An identical result good or bad leads to a system which is reporducible and therefore buildable, which is the foundation of all good architecture

This is fully self- contained bascis file samba file share simulation system. There are no external dependencies save for those which I have stored in the github release repository for the samba server and client including the ubuntu base image that they are running in within the container runtime evnvironment (cre- in this case containerd). The docker images for both samaba client and server are built locally by the installation script and the . The accessibility of these images as well as the depedencies is questionable. On docker images are often renamed or removes and I've the same expereince with cloud or mirror repositories.

There is the risk of wsl2 vm layer courruption when two or more cres are installed on a single distro. I understand many sw engineers use docker desktop which often uses the wsl2 default distro. Docker, Podman, Rancher, Minikube, and Colima 

These CREs all attempt to control the same subsystems:

    cgroups (v1/v2 mode, hierarchy mounts)

    containerd (socket ownership, runtime shims)

    iptables (NAT, MASQUERADE, bridge rules)

    systemd (unit files, service dependencies)

    mount namespaces (overlayfs, cgroup mounts, /run)
The cres will all inevitabley compete for the same  shared kernel‑level resources  allowed to them by them by the vm, corruption at the vm layer is inevevitable. To prevent this from happening, a user accidentally installing k3s on the distro with another cre, I made the script create another dedicated k3s distro. It will shutdown the current default distro and then install a dedicated Ubuntu k3s distro.  