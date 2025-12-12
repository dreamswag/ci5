#!/bin/sh
uci set sqm.eth1=queue
uci set sqm.eth1.interface='eth1'
uci set sqm.eth1.qdisc='cake'
uci set sqm.eth1.script='layer_cake.qos'
# DISABLED BY DEFAULT - Enabled by Speed Wizard
uci set sqm.eth1.enabled='0' 
uci commit sqm
