#!/bin/bash

echo "Waiting for \"$1\" host to be available in /etc/hosts"

while [[ $(grep $1 /etc/hosts | wc -l) -eq 0 ]]; do 
    sleep 1
done

sleep 2

ping6 -w 120 -c 1 $1

echo "\"$1\" present in /etc/hosts:"

# print the address
grep $1 /etc/hosts
