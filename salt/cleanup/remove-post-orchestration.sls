include:
  - kubectl-config

{%- set target = salt['pillar.get']('target') %}

{%- set k8s_nodes = salt['mine.get']('roles:(kube-master|kube-minion|etcd)', 'nodename', 'grain_pcre').keys() %}

###############
# k8s cluster
###############

{%- if target in k8s_nodes %}

{%- from '_macros/kubectl.jinja' import kubectl with context %}

{{ kubectl("remove-node",
           "delete node " + target,
           check_cmd="/bin/true") }}

{% endif %}
