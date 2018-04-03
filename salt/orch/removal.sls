# must provide the node (id) to be removed in the 'target' pillar
{%- set target = salt['pillar.get']('target') %}

# when the target is unresponsive, we can force the removal
{%- set forced = salt['pillar.get']('forced', '') %}

{#- ... and we can provide an optional replacement node #}
{%- set replacement = salt['pillar.get']('replacement', '') %}

{#- an expression for matching the target #}
{%- set target_tgt = target %}

{#- Get a list of nodes seem to be down or unresponsive #}
{#- This sends a "are you still there?" message to all #}
{#- the nodes and wait for a response, so it takes some time. #}
{#- Hopefully this list will not be too long... #}
{%- set nodes_down = salt.saltutil.runner('manage.down') %}
{%- if nodes_down|length >= 1 %}
  {%- do salt.caasp_log.debug('nodes "%s" seem to be down: ignored', nodes_down|join(',')) %}
  {%- set is_responsive_node_tgt = 'not L@' + nodes_down|join(',') %}

  {%- if target in nodes_down %}
    {%- if not forced %}
      {%- do salt.caasp_log.abort('target is unresponsive, and removal is not forced') %}
    {%- endif %}

    {%- do salt.caasp_log.debug('target is unresponsive. Forcing removal') %}
    {%- set target_tgt = '' %}  {# will not match anything #}
  {%- endif %}

{%- else %}
  {%- do salt.caasp_log.debug('all nodes seem to be up') %}
  {#- we cannot leave this empty (it would produce many " and <empty>" targets) #}
  {%- set is_responsive_node_tgt = '*' %}
{%- endif %}

{%- set etcd_members = salt.saltutil.runner('mine.get', tgt='G@roles:etcd',        fun='network.interfaces', tgt_type='compound').keys() %}
{%- set masters      = salt.saltutil.runner('mine.get', tgt='G@roles:kube-master', fun='network.interfaces', tgt_type='compound').keys() %}
{%- set minions      = salt.saltutil.runner('mine.get', tgt='G@roles:kube-minion', fun='network.interfaces', tgt_type='compound').keys() %}

{%- set super_master_tgt = salt.caasp_nodes.get_super_master(masters=masters,
                                                             excluded=[target] + nodes_down) %}
{%- if not super_master_tgt %}
  {%- do salt.caasp_log.abort('no masters seem to be reachable') %}
{%- endif %}

{#- try to use the user-provided replacement or find a replacement by ourselves #}
{#- if no valid replacement can be used/found, `replacement` will be '' #}
{%- set replacement, replacement_roles = salt.caasp_nodes.get_replacement_for(target, replacement,
                                                                              masters=masters,
                                                                              minions=minions,
                                                                              etcd_members=etcd_members,
                                                                              excluded=nodes_down) %}


{##############################
 # set grains
 #############################}

assign-removal-grain:
  salt.function:
    - tgt: '{{ target_tgt }}'
    - name: grains.setval
    - arg:
      - removal_in_progress
      - true

{%- if replacement %}

assign-addition-grain:
  salt.function:
    - tgt: {{ replacement }}
    - name: grains.setval
    - arg:
      - addition_in_progress
      - true

  {#- and then we can assign these (new) roles to the replacement #}
  {% for role in replacement_roles %}
assign-{{ role }}-role-to-replacement:
  salt.function:
    - tgt: {{ replacement }}
    - name: grains.append
    - arg:
      - roles
      - {{ role }}
    - require:
      - assign-removal-grain
      - assign-addition-grain
  {%- endfor %}

{%- endif %} {# replacement #}

sync-all:
  salt.function:
    - tgt: '{{ is_responsive_node_tgt }}'
    - names:
      - saltutil.refresh_pillar
      - saltutil.refresh_grains
      - mine.update
      - saltutil.sync_all
    - require:
      - assign-removal-grain
  {%- for role in replacement_roles %}
      - assign-{{ role }}-role-to-replacement
  {%- endfor %}

{##############################
 # replacement setup
 #############################}

{%- if replacement %}

highstate-replacement:
  salt.state:
    - tgt: {{ replacement }}
    - highstate: True
    - require:
      - sync-all

set-bootstrap-complete-flag-in-replacement:
  salt.function:
    - tgt: {{ replacement }}
    - name: grains.setval
    - arg:
      - bootstrap_complete
      - true
    - require:
      - highstate-replacement

# remove the we-are-adding-this-node grain
remove-addition-grain:
  salt.function:
    - tgt: {{ replacement }}
    - name: grains.delval
    - arg:
      - addition_in_progress
    - kwarg:
        destructive: True
    - require:
      - assign-addition-grain
      - set-bootstrap-complete-flag-in-replacement

{%- endif %} {# replacement #}

{##############################
 # removal & cleanups
 #############################}

# the replacement should be ready at this point:
# we can remove the old node running in {{ target }}

prepare-target-removal:
  salt.state:
    - tgt: '{{ super_master_tgt }}'
    - sls:
      - cleanup.remove-pre-stop-services
    - require:
      - sync-all
  {%- if replacement %}
      - set-bootstrap-complete-flag-in-replacement
  {%- endif %}

stop-services-in-target:
  salt.state:
    - tgt: '{{ target_tgt }}'
    - sls:
      - container-feeder.stop
  {%- if target in masters %}
      - kube-apiserver.stop
      - kube-controller-manager.stop
      - kube-scheduler.stop
  {%- endif %}
      - kubelet.stop
      - kube-proxy.stop
      - docker.stop
  {%- if target in etcd_members %}
      - etcd.stop
  {%- endif %}
    - require:
      - sync-all
  {%- if target in etcd_members %}
      - prepare-target-removal
  {%- endif %}

# remove any other configuration in the machines
cleanups-in-target-before-rebooting:
  salt.state:
    - tgt: '{{ target_tgt }}'
    - sls:
  {%- if target in masters %}
      - kube-apiserver.remove-pre-reboot
      - kube-controller-manager.remove-pre-reboot
      - kube-scheduler.remove-pre-reboot
      - addons.remove-pre-reboot
      - addons.dns.remove-pre-reboot
      - addons.tiller.remove-pre-reboot
      - addons.dex.remove-pre-reboot
  {%- endif %}
      - kube-proxy.remove-pre-reboot
      - kubelet.remove-pre-reboot
      - kubectl-config.remove-pre-reboot
      - docker.remove-pre-reboot
      - cni.remove-pre-reboot
  {%- if target in etcd_members %}
      - etcd.remove-pre-reboot
  {%- endif %}
      - etc-hosts.remove-pre-reboot
      - motd.remove-pre-reboot
      - cleanup.remove-pre-reboot
    - require:
      - stop-services-in-target

# finish the removal by running some final cleanups
# in the super_master
cleanups-in-super-master:
  salt.state:
    - tgt: '{{ super_master_tgt }}'
    - pillar:
        target: {{ target }}
    - sls:
      - cleanup.remove-post-orchestration
    - require:
      - cleanups-in-target-before-rebooting

# shutdown the node
shutdown-target:
  salt.function:
    - tgt: '{{ target_tgt }}'
    - name: cmd.run
    - arg:
      - sleep 15; systemctl poweroff
    - kwarg:
        bg: True
    - require:
      - cleanups-in-super-master
    # (we don't need to wait for the node:
    # just forget about it...)

# remove the Salt key
# (it will appear as "unaccepted")
remove-target-salt-key:
  salt.wheel:
    - name: key.delete
    - match: {{ target }}
    - require:
      - shutdown-target

# revoke certificates
# TODO

# We should update some things in rest of the machines
# in the cluster (even though we don't really need to restart
# services). For example, the list of etcd servers in
# all the /etc/kubernetes/apiserver files is including
# the etcd server we have just removed (but they would
# keep working fine as long as we had >1 etcd servers)

{%- set affected_tgt = salt.caasp_nodes.get_expr_affected_by(target,
                                                             excluded=[replacement] + nodes_down,
                                                             masters=masters,
                                                             minions=minions,
                                                             etcd_members=etcd_members) %}
{%- do salt.caasp_log.debug('will high-state machines affected by removal: "%s"', affected_tgt) %}

highstate-affected:
  salt.state:
    - tgt: '{{ affected_tgt }}'
    - tgt_type: compound
    - highstate: True
    - batch: 1
    - require:
      - remove-target-salt-key
