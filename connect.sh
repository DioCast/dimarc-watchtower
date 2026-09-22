#!/bin/bash

# 1. Ensure we can find standard tools like gcloud
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# 2. Go to the project folder
cd /Users/dio/Developer/dimarc-watchtower

# 3. Run the Bridge using the VERIFIED Absolute Path
/Users/dio/Developer/dimarc-watchtower/.venv/bin/python bridge.py