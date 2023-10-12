#!/bin/sh

sfdisk -X gpt "${disk}" <<EOF
,$bootpartitionsize,U 
;
EOF

diskpart1=$(lsblk $disk -nlp --output NAME | sed -n "2p")
diskpart2=$(lsblk $disk -nlp --output NAME | sed -n "3p")
