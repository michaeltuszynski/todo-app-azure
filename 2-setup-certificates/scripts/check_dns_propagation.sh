#!/bin/bash

# Ensure a domain is provided as a parameter
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <domain> <expected_value> <record_type>"
    exit 1
fi

# Domain and expected TXT record value
DOMAIN="$1"
EXPECTED_VALUE="$2"
RECORD_TYPE="$3"

# DNS servers to check
DNS_SERVERS=(
    "1.1.1.1"         # Cloudflare
    "1.0.0.1"         # Cloudflare
    "75.75.75.75"     # Comcast
    "75.75.76.76"     # Comcast
)

# Max attempts to check DNS propagation
MAX_ATTEMPTS=2

# Time to sleep between attempts in seconds
SLEEP_TIME=10

# Attempt counter
ATTEMPT=0

# Log file path
LOG_FILE="./scripts/dns_${RECORD_TYPE}_propagation.log"

# Clear previous log file
echo "" > "$LOG_FILE"

# JSON output variable
JSON_OUTPUT="{"

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
  FOUND="true"
  JSON_OUTPUT="{"

  for server in "${DNS_SERVERS[@]}"; do
    RESULT=$(dig @$server +short $RECORD_TYPE $DOMAIN)
    RESULT=$(echo $RESULT | tr -d '"')
    
    # Get the current timestamp
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

    # Check if the result matches the expected value
    if [ "$RESULT" != "$EXPECTED_VALUE" ]; then
      FOUND="false"
      JSON_OUTPUT+="\"server_${server//./_}\": \"not found\","
      echo "$TIMESTAMP - $DOMAIN @ $server: not found" >> "$LOG_FILE"
    else
      JSON_OUTPUT+="\"server_${server//./_}\": \"found\","
      echo "$TIMESTAMP - $DOMAIN @ $server: found" >> "$LOG_FILE"
    fi
  done

  # Remove trailing comma and close JSON object
  JSON_OUTPUT="${JSON_OUTPUT%,}}"

  # If the record was found on all DNS servers, break the loop
  if [ "$FOUND" == "true" ]; then
    break
  fi

  # Increment the attempt counter and sleep before trying again
  ATTEMPT=$((ATTEMPT + 1))
  #echo "Attempt $ATTEMPT/$MAX_ATTEMPTS . Trying again in $SLEEP_TIME seconds..."

  sleep "$SLEEP_TIME"
done

# Output the JSON object with the result
echo $JSON_OUTPUT