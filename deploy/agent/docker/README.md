# Deploy agents on a server 

This will deploy the wazuh agent as a docker contioaner on a server.
The wazuih agent run insidte a container gives it several benifits 

-  It run insolated from the host and cant be affected by host updated and libs
-  Harder to trick you dont have access to the wazug binaries and only to the host system
-  Miltipel agents running on the same host with diffrent task (fim,logfile) this improve scale in larger systems



## Deploy
We have 2 deploy files one docker+compsoe that gives full access of the docker to the host.
This is the one of you want to monitor the full host, Including network access
The other will only monitor and common logfiles


## Docker Compose


## Config
When the pod start it will update the ossec.conf from a template. You can configure by update the template and mount the template in the temple folder.
Then the init script till update you template and add it to the wazuh agents


### Env
All basic config is done by env variables. as following

¨¨¨      
      - MANAGER_URL=192.168.1.36 # Manager ip 
      - MANAGER_PORT=32466  # should go to manager port 1515
      - SERVER_URL=192.168.1.36 # Worker IP
      - SERVER_PORT=30851   # should go to worker port 1514
      - NAME=docker-anything-33 # name update need to be new so it can register
      - GROUP=default  #The groups need to create in wazuh before you can add then
      - ENROL_TOKEN=CUSTOM_PASSWORD  # set the token to enroll 

¨¨¨

## Connect to our K8s cluster
To connect to our k8s cluster we need to get the right values from our svc run this command in the k8s cluster to get oure values



¨¨¨
mattias@base:~/projects/samma/wazuh-agent$ kubectl get svc -n wazuh 
NAME                     TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)                          AGE
wazuh                    NodePort       10.111.60.88     <none>        1515:31254/TCP,55000:30397/TCP   2d22h
wazuh-cluster            ClusterIP      10.99.222.173    <none>        1516/TCP                         2d22h
wazuh-dashboard          NodePort       10.110.165.149   <none>        5601:30272/TCP                   2d22h
wazuh-indexer            ClusterIP      10.105.57.69     <none>        9200/TCP                         2d22h
wazuh-manager            ClusterIP      10.97.83.140     <none>        1515/TCP,1516/TCP,55000/TCP      2d22h
wazuh-workers            LoadBalancer   10.110.126.132   10.0.0.106    1514:30418/TCP                   2d22h
wazuh-workers-nodeport   NodePort       10.108.186.178   <none>        1514:31302/TCP                   2d22h
¨¨¨

### Create client group
Login into wazuh and create a grpup for you agents.


### Worker
From this we see that we have the workers on 

Loadbalancer:
ip 10.0.0.106 and the port 1514

Ore we can use the nodeport
Ip one of you k8s worker nodes ip port 31302


### Manager

Ip one of the workers ip and port 31254

### Onroll token


The command
¨¨¨
kubectl edit cm wazuh-register-key -n wazuh 
¨¨¨

Will give you the enroll token to use.


