#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Синтетический набор cell_conf/*.conf и R3_preconf_ex9s.csv для публикации на GitHub.

Заменяет реальные данные (гксм/сеть 10.64.84.x, MAC Oracle a8:69:8c, DNS 172.16.x)
полностью вымышленными, взятыми из зарезервированных документационных диапазонов
RFC 5737 / RFC 2606 / RFC 7042:

    Домен            example.test            (RFC 2606)
    Management (eth0+ILOM):   192.0.2.0/24   (TEST-NET-1, RFC 5737)
    Private (re0/re1):        198.51.100.0/22 (TEST-NET-2, RFC 5737)
    DNS/NTP (корневые и ILOM):203.0.113.x    (TEST-NET-3, RFC 5737)
    MAC                       00:00:5e:00:53:NN (OUI IANA doc, RFC 7042)

Схема адресов (NN = номер ячейки 01..40):
    re0  -> 198.51.100.{2*(NN-1)+101}      re1 -> re0+1
    eth0 -> 192.0.2.{NN+20}                ilom -> 192.0.2.{NN+36}
    gw (mgmt и ilom) 192.0.2.254, netmask mgmt 255.255.255.0, priv 255.255.252.0
    DNS 203.0.113.10 203.0.113.11          NTP 203.0.113.20 203.0.113.21

Имена хостов нейтральные:
    ячейка        exacellNN.example.test
    priv1/priv2   exacellNN-priv1/priv2.example.test
    ilom          exacellNN-ilom.example.test  (short: exacellNN-ilom)
    БД            exadb04, exadb05

Структура конфигов сохранена посимвольно как в реальных источниках (по одному тегу
на строку, ровно 2 <Nameservers>, 2 <Ntp_servers>, 1 блок eth0, блок <ilom>), так
что update_cell_conf.sh проходит с ними без изменений. У ячейки exacell27, как и в
реальной базе, нет тега <Pkeyconfigured> (75 строк вместо 76) — вариант, который
скрипт тоже должен корректно обработать.
"""

import os
import hashlib

DOMAIN = "example.test"
TZ = "Europe/Moscow"
GW = "192.0.2.254"
MGMT_NM = "255.255.255.0"
PRIV_NM = "255.255.252.0"
DNS = "203.0.113.10"
DNS2 = "203.0.113.11"
NTP = "203.0.113.20"
NTP2 = "203.0.113.21"
BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "github_public")
CONF_DIR = os.path.join(OUT, "cell_conf")


def cell_ips(nn):
    priv = 2 * (nn - 1) + 101                      # re0 base
    return dict(
        re0="198.51.100.%d" % priv,
        re1="198.51.100.%d" % (priv + 1),
        eth0="192.0.2.%d" % (nn + 20),
        ilom="192.0.2.%d" % (nn + 36),
        mac="00:00:5e:00:53:%02x" % nn,
    )


def short(nn):
    return "exacell%02d" % nn


def fq(name):
    return "%s.%s" % (name, DOMAIN)


def make_conf(nn):
    s = short(nn)
    ip = cell_ips(nn)
    has_pkey = (nn != 27)          # как в реальной базе: у cell27 тега нет
    lines = []
    lines.append("<?xml version='1.0' standalone='yes'?>")
    lines.append("<Cell>")
    lines.append("  <Hostname>%s</Hostname>" % fq(s))
    lines.append("  <Active_bond_ib>yes</Active_bond_ib>")
    lines.append("  <Default_gateway_device>eth0</Default_gateway_device>")
    # re0
    lines.append("  <Interfaces>")
    lines.append("    <Hostname>%s</Hostname>" % fq("%s-priv1" % s))
    lines.append("    <IP_address>%s</IP_address>" % ip["re0"])
    lines.append("    <IP_enabled>yes</IP_enabled>")
    lines.append("    <IP_ssh_listen>enabled</IP_ssh_listen>")
    lines.append("    <Inet_protocol>IPv4</Inet_protocol>")
    lines.append("    <Name>re0</Name>")
    lines.append("    <Net_type>Private</Net_type>")
    lines.append("    <Netmask>%s</Netmask>" % PRIV_NM)
    lines.append("    <State>1</State>")
    lines.append("    <Status>UP</Status>")
    lines.append("  </Interfaces>")
    # re1
    lines.append("  <Interfaces>")
    lines.append("    <Hostname>%s</Hostname>" % fq("%s-priv2" % s))
    lines.append("    <IP_address>%s</IP_address>" % ip["re1"])
    lines.append("    <IP_enabled>yes</IP_enabled>")
    lines.append("    <IP_ssh_listen>enabled</IP_ssh_listen>")
    lines.append("    <Inet_protocol>IPv4</Inet_protocol>")
    lines.append("    <Name>re1</Name>")
    lines.append("    <Net_type>Private</Net_type>")
    lines.append("    <Netmask>%s</Netmask>" % PRIV_NM)
    lines.append("    <State>1</State>")
    lines.append("    <Status>UP</Status>")
    lines.append("  </Interfaces>")
    # eth0 (management)
    lines.append("  <Interfaces>")
    lines.append("    <Bond_type>single</Bond_type>")
    lines.append("    <Gateway>%s</Gateway>" % GW)
    lines.append("    <Hostname>%s</Hostname>" % fq(s))
    lines.append("    <IP_address>%s</IP_address>" % ip["eth0"])
    lines.append("    <IP_enabled>yes</IP_enabled>")
    lines.append("    <IP_ssh_listen>enabled</IP_ssh_listen>")
    lines.append("    <Inet_protocol>IPv4</Inet_protocol>")
    lines.append("    <Name>eth0</Name>")
    lines.append("    <Net_type>Management</Net_type>")
    lines.append("    <Netmask>%s</Netmask>" % MGMT_NM)
    lines.append("    <State>1</State>")
    lines.append("    <Status>UP</Status>")
    lines.append("    <Vlan_id>0</Vlan_id>")
    lines.append("  </Interfaces>")
    lines.append("  <Internal>")
    lines.append("    <Interface_ethernet_prefix>eth</Interface_ethernet_prefix>")
    lines.append("    <Interface_infiniband_prefix>re</Interface_infiniband_prefix>")
    lines.append("  </Internal>")
    lines.append("  <Nameservers>%s</Nameservers>" % DNS)
    lines.append("  <Nameservers>%s</Nameservers>" % DNS2)
    lines.append("  <Node_type>cell</Node_type>")
    lines.append("  <Ntp_drift>/var/lib/chrony/drift</Ntp_drift>")
    lines.append("  <Ntp_servers>%s</Ntp_servers>" % NTP)
    lines.append("  <Ntp_servers>%s</Ntp_servers>" % NTP2)
    if has_pkey:
        lines.append("  <Pkeyconfigured>no</Pkeyconfigured>")
    lines.append("  <Qinq_vlan_id>0</Qinq_vlan_id>")
    lines.append("  <System_active>non-ovs</System_active>")
    lines.append("  <Timezone>%s</Timezone>" % TZ)
    lines.append("  <Version>24.1.0.0.0</Version>")
    lines.append("  <ilom>")
    lines.append("    <ILOM_First_NTP_server>%s</ILOM_First_NTP_server>" % NTP)
    lines.append("    <ILOM_Fully_qualified_hostname>%s</ILOM_Fully_qualified_hostname>" % fq("%s-ilom" % s))
    lines.append("    <ILOM_Gateway>%s</ILOM_Gateway>" % GW)
    lines.append("    <ILOM_IP_address>%s</ILOM_IP_address>" % ip["ilom"])
    lines.append("    <ILOM_IP_discovery>static</ILOM_IP_discovery>")
    lines.append("    <ILOM_Nameserver>%s,%s</ILOM_Nameserver>" % (DNS, DNS2))
    lines.append("    <ILOM_Netmask>%s</ILOM_Netmask>" % MGMT_NM)
    lines.append("    <ILOM_Search>%s</ILOM_Search>" % DOMAIN)
    lines.append("    <ILOM_Second_NTP_server>%s</ILOM_Second_NTP_server>" % NTP2)
    lines.append("    <ILOM_Short_Hostname>%s-ilom</ILOM_Short_Hostname>" % s)
    lines.append("    <ILOM_Timezone>%s</ILOM_Timezone>" % TZ)
    lines.append("    <ILOM_Use_NTP_Servers>enabled</ILOM_Use_NTP_Servers>")
    lines.append("    <ILOM_Vlan_id>0</ILOM_Vlan_id>")
    lines.append("    <Inet_protocol>IPv4</Inet_protocol>")
    lines.append("  </ilom>")
    lines.append("</Cell>")
    # реальный файл кончается переводом строки
    return "\n".join(lines) + "\n"


def cell_csv_row(nn):
    """28 полей, как в реальной строке ячейки preconf."""
    s = short(nn)
    ip = cell_ips(nn)
    f = [
        s,                          # 1 hostname
        DOMAIN,                     # 2 domain
        "cell",                     # 3 node type
        "eth0",                     # 4 gateway device
        "eth0:::::::",              # 5 eth interface
        "Management",               # 6 eth type
        ip["mac"],                  # 7 mac address
        ip["eth0"],                 # 8 ip
        MGMT_NM,                    # 9 netmask
        GW,                         # 10 gateway
        "%s.example.test" % ("%s-priv1" % s),   # 11 bondib hostname
        "Private:active-bond-ib:",  # 12 bondib type
        ip["re0"],                  # 13 bondib ip
        PRIV_NM,                    # 14 bondib netmask
        "%s %s" % (DNS, DNS2),      # 15 nameservers
        "%s %s" % (NTP, NTP2),      # 16 ntps
        TZ,                         # 17 timezone
        "ilom:",                    # 18 marker
        "%s-ilom.example.test" % s, # 19 ilom fqdn
        ip["ilom"],                 # 20 ilom ip
        MGMT_NM,                    # 21 ilom netmask
        GW,                         # 22 ilom gateway
        "%s %s" % (DNS, DNS2),      # 23 ilom nameservers
        "enabled",                  # 24 enabled
        NTP,                        # 25 ilom ntp1
        NTP2,                       # 26 ilom ntp2
        "",                         # 27
        "",                         # 28
    ]
    return ",".join(f)


def db_csv_row(nn):
    """34 поля, как в реальной строке БД-сервера preconf."""
    s = "exadb%02d" % nn
    ip = cell_ips(nn)                      # тот же шаблон адресов для БД-хостов
    priv = ip["re0"][:ip["re0"].rfind(".")+1]
    f = [
        s, "example.test", "dbpp", "bondeth0", "eth0:::::::",
        "Management",
        "00:00:5e:00:53:%02x" % (40 + nn),  # distinct MAC block for dbs
        ip["eth0"], MGMT_NM, GW,
        "%s-priv1.example.test" % s,
        "Private:active-bond-ib:",
        ip["re0"], PRIV_NM,
        "%s %s" % (DNS, DNS2),
        "%s %s" % (NTP, NTP2),
        TZ, "ilom:",
        "%s-ilom.example.test" % s,
        ip["ilom"], MGMT_NM, GW,
        "%s %s" % (DNS, DNS2),
        "enabled", NTP, NTP2,
        "",
        "bondeth0:lacp::ssh-listen-disabled::link-speed-25000:",
        "SCAN", "eth8 eth12",
        "10.0.0.%d" % (100 + nn), MGMT_NM, "10.0.0.254",
        "exa%02d.example.test" % nn,
    ]
    assert len(f) == 34, len(f)
    return ",".join(f)


def render_csv():
    head = [
        "Cell,Preconfig,version,11.2.2.1.0,,,,,,,",
        "",
        "# WARNING - DO NOT EDIT THIS FILE USING EXCEL",
        "",
        "# IMPORTANT - YOU DO NOT NEED TO MERGE THE MAC ADDRESSES INTO THIS FILE",
        "",
        "# OneCommand,XXX,Exadata Elastic Rack",
        "",
        "# This is a main format for 11.2.2.1.0",
        "",
        "hostname,domain,node type,gateway device,eth interface,eth type,mac address,ip,netmask,gateway,bondib hostname,bondib type,bondib ip,bondib netmask,nameservers,ntps,timezone",
        "",
        "# DO NOT edit the above lines",
        "#",
        "",
        "#",
        "#cell",
    ]
    cells_group1 = [40, 33, 32, 31, 36, 35, 34]
    cells_group2 = [39, 38, 37, 30, 29, 28, 27]
    rows = list(head)
    for n in cells_group1:
        rows.append(cell_csv_row(n))
    rows += ["#", "#comp", db_csv_row(5), db_csv_row(4), "#", "#cell"]
    for n in cells_group2:
        rows.append(cell_csv_row(n))
    rows += ["", "# Do NOT edit below this line", ",,,,,,,,,,"]
    return "\n".join(rows) + "\n"


def main():
    os.makedirs(CONF_DIR, exist_ok=True)
    # 1) conf files
    for nn in range(1, 41):
        path = os.path.join(CONF_DIR, "cell_%s.conf" % short(nn))
        with open(path, "w", newline="\n") as fh:
            fh.write(make_conf(nn))
    # 2) sum.md5
    md5path = os.path.join(CONF_DIR, "sum.md5")
    with open(md5path, "w", newline="\n") as mf:
        for nn in range(1, 41):
            fn = "cell_%s.conf" % short(nn)
            with open(os.path.join(CONF_DIR, fn), "rb") as cf:
                digest = hashlib.md5(cf.read()).hexdigest()
            mf.write("%s  %s\n" % (digest, fn))
    # 3) CSVs
    body = render_csv()
    for fn in ("R3_preconf_ex9s.csv", "R3_preconf_ex9s_example.csv"):
        with open(os.path.join(OUT, fn), "w", newline="\n") as fh:
            fh.write(body)
    print("Generated into:", OUT)
    print("  conf files:", len(os.listdir(CONF_DIR)))
    print("  csv bytes: ", len(body))


if __name__ == "__main__":
    main()