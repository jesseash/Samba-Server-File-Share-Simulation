**Prerequisites:**  Windows 10 Pro or > WSL2 already enabled


**Directions:** This script assumes you have wls2 already enabled. Open a power shell console with admin privileges. In the root directory run:                             
                    
                    
                    
                    
                    
              .\scripts\run_windows_setup.cmd 


Open windows console with admin privileges (in my experience the ps shim doesn't work well for this specific task). Now run 
              
              wsl.exe -d Ubuntu-k3s

this will start a tty session with the k3s dedicated distro.              

**Expected output:**

The script takes between 10-15 minutes to run- it might be a little faster running on a native os as opposed to a vm. I've made it purposely verbose and full of diagnostics only so I could better pin point environmental issues. If the installation was successful you should see this at the very end of the output.


       === Verifying client pod file-system activity ===
       [post-clone] Selected client pod: samba-users-7d98979cd8-7qb5d
       [post-clone] Selected samba pod: samba-867d4b7df-shpqs (container: samba)
       [post-clone] Recent client pod logs (tail=80):
       [client-log] [INFO] Client starting on samba-users-7d98979cd8-7qb5d
       [client-log] [INFO] Current time: 2026-07-18T16:39:57+00:00
       [client-log] [INFO] Environment:
       [client-log] ------------------------------------------------------------
       [client-log] Hostname: samba-users-7d98979cd8-7qb5d
       [client-log] Pod name: samba-users-7d98979cd8-7qb5d
       [client-log] ------------------------------------------------------------
       [client-log] [INFO] Client ID for SMB identity: c-7qb5d
       [client-log] [INFO] Waiting for Samba service on port 445...
       [client-log] [OK] Samba is reachable on port 445
       [client-log] [INFO] Attempting CIFS mount...
       [client-log] [OK] Mounted //samba.default.svc.cluster.local/share on /mnt/samba
       [client-log] [INFO] Share already contains files
       [client-log] [INFO] Entering main loop...
       [client-log] [DELETE] Removing all files
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392800.txt
       [client-log] [DELETE] Removing all files
       [client-log] [DELETE] Removing all files
       [client-log] [READ] Listing directory contents
       [client-log] [READ] Listing directory contents
       [client-log] [DELETE] Removing all files
       [client-log] [DELETE] Removing all files
       [client-log] [READ] Listing directory contents
       [client-log] [READ] Listing directory contents
       [client-log] [DELETE] Removing all files
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392829.txt
       [client-log] [DELETE] Removing all files
       [client-log] [READ] Listing directory contents
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392836.txt
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392839.txt
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392843.txt
       [client-log] [DELETE] Removing all files
       [client-log] [DELETE] Removing all files
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392853.txt
       [client-log] [READ] Listing directory contents
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392860.txt
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392865.txt
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392867.txt
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392868.txt
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392870.txt
       [client-log] [DELETE] Removing all files
       [client-log] [DELETE] Removing all files
       [client-log] [DELETE] Removing all files
       [client-log] [DELETE] Removing all files
       [client-log] [READ] Listing directory contents
       [client-log] [WRITE] Creating file: /mnt/samba/samba-users-7d98979cd8-7qb5d-write-1784392892.txt
       [post-clone] [OK] Client file-system updates are working (token 'proof-1784392896' verified on samba volume).

       === Completed ===
       [post-clone] Default distro at end: Ubuntu

       ======================================================
        WSL post-clone setup is complete.
         ======================================================
         Repo mirrored to    : /home/jesse/Samba-Server-File-Share-Simulation
         Windows kubeconfig  : C:\Users\Jesse\.kube\config
         Active k3s distro   : wsl -d Ubuntu-k3s

         NOTE: Your default distro 'Ubuntu' was stopped for isolation.
          To restart it, run:  wsl -d Ubuntu
        ======================================================


After you run  wsl.exe -d Ubuntu-k3s to start a tty session with WSL2 you should be able to connect with Freelens and view pod activity via the logs.
![Lens Screen shot](/lensview.png)




**Description:** 

The Samba Server is our linux based alternative to windows ad, which will be the foundation of our business simulation. As the simulation grows in complexity- and we add more components to our k3s cluster ( such as a database, flat files for the ingestion of data, a claude coding agent, an inference gateway for multiple different LLMs and corresponding users) we will eventaully move this off of WSL2 and on to a native Ubuntu OS.  Windows’s single user paradigm isn’t viable for Kubernetes aka cluster management software and WSL2 has finite resource limitiations. Eventually there will be windows machines included in the system but they won’t be directly part of the cluster- they will have remote access to proxy pods running on Ubuntu- which will be the command and control center of the cluster.

 This is a fully self- contained basic samba file share simulation system. There are no external dependencies save for those which I have stored in the github release repository for the samba server and client including the ubuntu base image that are running within the container runtime environment. The docker images for both samba client and server are built locally by the installation script. The accessibility of these images as well as the dependencies are questionable. On docker, images are often renamed or removes and I've had the same experience with cloud or mirror repositories.

There is the risk of wsl2 vm layer corruption when two or more cres are installed on a single distro. I understand many sw engineers use docker desktop which often uses the wsl2 default distro. Docker, Podman, Rancher, Minikube, and Colima 

These CREs all attempt to control the same subsystems:

    cgroups (v1/v2 mode, hierarchy mounts)

    containerd (socket ownership, runtime shims)

    iptables (NAT, MASQUERADE, bridge rules)

    systemd (unit files, service dependencies)

    mount namespaces (overlayfs, cgroup mounts, /run)
The cres will all inevitably compete for the same  shared kernel‑level resources  allowed to them by them by the vm, corruption at the vm layer is inevitable. To prevent this from happening, a user accidentally installing k3s on the distro with another cre, I made the script create another dedicated k3s distro. It will shutdown the current default distro and then install a dedicated Ubuntu k3s distro.




The images for samba server and client can be modified by running the rebuild-client and rebuild-server shell scrips respectively. Both docker files are set to build offline locally during or after the installation. After the images are modified both scripts are set to automatically redeploy. Below is a basic diagram of the installation pipeline.


![diagram](/installation_pipeline.jpg)



