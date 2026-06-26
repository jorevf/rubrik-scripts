#!/usr/local/bin/python3
#
# This is a simple python script to enable / disable wanThrottling in Rubrik NCD.
# To run the script you need upload / download speed in MB/sec
# Enable ( Values in MB )
# python3 /<path>/ncd_wanthrottle.py --enable --uplimit 100 --downlimit 100
#
# Disable
# python3 /<path>/ncd_wanthrottle.py --disable
#
# To get more output --verbose can be used.
# Some different crontab entries could be.
#
# Full steam ahead from Friday evening.
# * 22 * * 5    /usr/bin/python3 /<path>/ncd_wanthrottle.py --disable  >> /<path>/ncd_wanthrottle.log
#
# Limit speed to 100MB/sec from Monday morning at 7am
# * 7 * * 0     /usr/bin/python3 /<path>/ncd_wanthrottle.py --enable --uplimit 100 --downlimit >> /<path>/ncd_wanthrottle.log
#
# Ver 1.0 - Customer Ware
# F.Jorevall @ Rubrik 2024-11-21

import requests
import json
import os.path
import hashlib
import sys
import argparse
import datetime
import pprint
from requests.packages.urllib3.exceptions import InsecureRequestWarning

def screenput(data):
    if verbose:
         print(data)

def main(argv):

# Initiate the parser
    parser = argparse.ArgumentParser()

# Add long and short argument
    parser.add_argument("--enable", "-e",  help="Enable WAN Throttling",        action='store_true')
    parser.add_argument("--disable", "-d",    help="Disable WAN Throttling",   action='store_true')
    parser.add_argument("--uplimit", "-ul",      help="upload limit in MB/sec",           required=False)
    parser.add_argument("--downlimit", "-dl",      help="download limit in MB/sec",        required=False)
    parser.add_argument("--verbose", "-V",      help="Verbose output",              action='store_true')
    
    arga=sys.argv[1:]
    nrargs=len(arga)

    args = parser.parse_args()

    if args.verbose:
        global verbose
        verbose = True
        screenput("Verbose output")
    else:
        verbose = False

    if nrargs == 0:
        parser.print_help(sys.stderr)
        sys.exit(16)

    else:
        args2 = parser.parse_args(sys.argv[1:])
        screenput(
                "Applied arguments : \n "
                "%s" % args2 + "\n"
            )

    if args.disable:
        screenput("Disable WAN throttling")
        wanThrottling = False
#   A value is needed even if we disable the throttling, so we use the lowest value posible.        
        uploadLimit = 125000
        downloadLimit = 125000

    if args.enable:
        screenput("Enable WAN throttling")
        wanThrottling = True
        if args.uplimit:
            screenput("Set upload throttling to %s " % args.uplimit + " MB/sec")
            uploadLimit = int(args.uplimit)
            uploadLimit *= 1024000
        else:
            print("Need an upload limit value in MB/Sec")
            exit(2)
        
        if args.downlimit:
            screenput("Set download throttling to %s " % args.downlimit + " MB/sec")
            downloadLimit = int(args.downlimit)
            downloadLimit *= 1024000
        else:
            print("Need an download limit value in MB/Sec")
            exit(3)

    access_token    = "<ncd access token>"
    url             = "https://<custmer ncd tenant>.nascd.rubrik.com"
    api_call        = "/x/igneous/v2/wan-throttling-config"

    jsonData = {
                'WANThrottlingEnabled': wanThrottling,
                'WANThrottlingUpLimit': uploadLimit,
                'WANThrottlingDownLimit': downloadLimit
                } 

    headers = {
                "Authorization": access_token,
                "Content-Type": "application/json"
              }

    screenput(jsonData)

    result = requests.post(url+api_call, headers=headers, data=json.dumps(jsonData))
    if result.ok:
        screenput(result.text)
        pp = pprint.PrettyPrinter(indent=2, width=30, compact=True)
        pp.pprint(result.text)
    else:
        screenput(result.text)
        screenput(result.status_code)
        screenput("The script could not change WAN Throttling "  + "with upload limit  " + str(uploadLimit) + " and download limit " + str(downloadLimit))
        exit(5)

if __name__ == '__main__':
    main(sys.argv)