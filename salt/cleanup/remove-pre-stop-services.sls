include:
  - kubectl-config

{%- set target = salt['pillar.get']('target') %}

{%- set etcd_members = salt['mine.get']('roles:etcd', 'nodename', 'grain').keys() %}

###############
# etcd node
###############

{%- if target in etcd_members %}

  {%- set nodename = salt.caasp_net.get_nodename(host=target) %}

etcd-remove-member:
  caasp_etcd.member_remove:
  - nodename: {{ nodename }}

{%- endif %}
