Local copy of `terraform-redhat/rosa-hcp` module `rosa-cluster-hcp` v1.7.5, plus a `no_cni` argument.

Upstream v1.7.5 requires provider `rhcs` >= 1.7.8, which supports `rhcs_cluster_rosa_hcp.no_cni`, but does not pass that argument through.
