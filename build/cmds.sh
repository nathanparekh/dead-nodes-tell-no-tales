# from prince
# Run the process container you want to migrate
# if container on podman make sure to run it with sudo
ps aux | grep "THE PID" # if process
sudo podman ps # if container
sudo podman container checkpoint <container_id> -e /tmp/checkpoint.tar.zst --tcp-established
scp /tmp/checkpoint.tar.zst <destination_system>:/tmp

# On destination_system
sudo podman container restore -i /tmp/checkpoint.tar.zst --tcp-established

# LIVE ITERATIVE MIGRATION
sudo podman ps
sudo podman container checkpoint <container_id> --pre-checkpoint -l -e /tmp/checkpoint.tar.zst
scp /tmp/checkpoint.tar.zst <destination_system>:/tmp
sudo podman container checkpoint <container_id> --with-previous --export /tmp/post.tar.gz -l
scp /tmp/post.tar.gz <destination_system>:/tmp

# On destination_system
sudo podman container restore --import /tmp/post.tar.gz --import-previous /tmp/checkpoint.tar.zst
