#!/bin/sh
uci set sqm.eth1=queue
uci set sqm.eth1.interface='eth1'
uci set sqm.eth1.qdisc='cake'
uci set sqm.eth1.script='layer_cake.qos'
uci set sqm.eth1.enabled='1'
# Default 500M symmetric - user changes via LUCI
uci set sqm.eth1.download='500000'
uci set sqm.eth1.upload='500000'
uci commit sqm
