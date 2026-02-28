# lib/k3s-defaults.nix
# Shared K3s tuning constants used by all k3s-* profiles.
# Keeps kubelet flags, IPVS settings, and etcd config in one place.
{lib}: {
  # Standard cluster CIDRs
  defaultClusterCIDR = "10.42.0.0/16";
  defaultServiceCIDR = "10.43.0.0/16";
  defaultClusterDNS = "10.43.0.10";

  # Common kubelet flags for production tuning
  serverKubeletFlags = [
    "--kubelet-arg=eviction-hard=memory.available<500Mi"
    "--kubelet-arg=eviction-hard=nodefs.available<5%"
    "--kubelet-arg=eviction-hard=nodefs.inodesFree<5%"
    "--kubelet-arg=eviction-hard=imagefs.available<5%"
    "--kubelet-arg=eviction-soft=memory.available<1Gi"
    "--kubelet-arg=eviction-soft-grace-period=memory.available=30s"
    "--kubelet-arg=serialize-image-pulls=false"
    "--kubelet-arg=max-pods=250"
    "--kubelet-arg=topology-manager-policy=best-effort"
    "--kubelet-arg=container-log-max-size=50Mi"
    "--kubelet-arg=container-log-max-files=5"
  ];

  # IPVS kube-proxy settings
  ipvsFlags = [
    "--kube-proxy-arg=proxy-mode=ipvs"
    "--kube-proxy-arg=ipvs-scheduler=lc"
    "--kube-proxy-arg=conntrack-max-per-core=131072"
  ];

  # API server concurrency tuning
  apiServerFlags = [
    "--kube-apiserver-arg=max-requests-inflight=800"
    "--kube-apiserver-arg=max-mutating-requests-inflight=400"
  ];

  # Controller manager tuning
  controllerManagerFlags = [
    "--kube-controller-manager-arg=node-cidr-mask-size=22"
    "--kube-controller-manager-arg=concurrent-deployment-syncs=10"
  ];

  # etcd snapshot configuration
  etcdSnapshotFlags = [
    "--etcd-snapshot-schedule-cron=0 4 * * *"
    "--etcd-snapshot-retention=10"
    "--etcd-snapshot-compress=true"
  ];

  # Common kernel modules for K3s nodes
  k3sKernelModules = [
    "br_netfilter"
    "overlay"
    "ip_vs"
    "ip_vs_rr"
    "ip_vs_wrr"
    "ip_vs_sh"
    "nf_conntrack"
  ];

  # All server extra flags combined
  allServerFlags = k3sDefaults:
    k3sDefaults.serverKubeletFlags
    ++ k3sDefaults.ipvsFlags
    ++ k3sDefaults.apiServerFlags
    ++ k3sDefaults.controllerManagerFlags
    ++ k3sDefaults.etcdSnapshotFlags;
}
