#!/bin/bash

# Set your OpenAI API key
OPENAI_API_KEY="${AUTO_COMMIT_OPENAI_API_KEY}"
# Set your OpenAI API endpoint
OPENAI_API_ENDPOINT="https://${AUTO_COMMIT_OPENAI_API_HOST}/v1/chat/completions"
# Set your Proxy, default using HTTPS_PROXY environment variable
CURL_PROXY=""

if [ "x$CURL_PROXY" = "x" ] ; then
    CURL_PROXY_OPT=""
else
    CURL_PROXY_OPT="--proxy ${CURL_PROXY}"
fi

# Default language for commit message
LANGUAGES="en"
# File to store user confirmation
CONFIRMATION_FILE="$HOME/.gptcommit_confirmed"

# ANSI color codes
RED='\033[0;31m'
NC='\033[0m' # No Color

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --lang=*) LANGUAGES="${1#*=}";;
        *) echo "Unknown parameter passed: $1"; exit 1;;
    esac
    shift
done

# Check for user confirmation
if [ ! -f "$CONFIRMATION_FILE" ]; then
    echo -e "${RED}Warning: This tool sends your code to an LLM, which may cause information leakage. Type YES to agree and not be prompted again.${NC}"
    read USER_CONFIRMATION
    if [ "$USER_CONFIRMATION" != "YES" ]; then
        echo "You did not confirm. Exiting."
        exit 1
    else
        echo "Confirmed." > "$CONFIRMATION_FILE"
    fi
fi

# Check the status of the working directory
echo "Checking the status of the working directory..."
git status

# Get the difference between the working directory and the staging area
WORKING_DIFF=$(git diff)
# Get the difference between the staging area and HEAD
STAGED_DIFF=$(git diff --cached)

# Combine the differences
DIFF="${WORKING_DIFF}${STAGED_DIFF}"

# If there are no differences, exit
if [ -z "$DIFF" ]; then
    echo "No differences found."
    exit 0
fi

# Call OpenAI's API to generate a commit message
generate_commit_message() {
    local LANGUAGES=$1
    RESPONSE=$(jq -n --arg diff "$DIFF" --arg lang "$LANGUAGES" '{
        model: "gpt-4o",
        messages: [
            {
                role: "user",
                content: "Analyze the following code changes and generate a concise Git commit message, providing it in the following languages: \($lang). Text only: \n\n\($diff)\n\n"
            }
        ],
        max_tokens: 500,
        temperature: 0.7
    }' | curl $CURL_PROXY_OPT --connect-timeout 5 -s "$OPENAI_API_ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -d @-)

    if [ $? -ne 0 ]; then
        echo "Error: OpenAI API call failed due to network error."
        exit 1
    fi

    if [ -z "$RESPONSE" ] || [ "$(echo "$RESPONSE" | jq -r '.error')" != "null" ]; then
        echo "Error: OpenAI API returned an error."
        exit 1
    fi

    echo "$RESPONSE" | jq -r '.choices[0].message.content' | sed 's/^"\(.*\)"$/\1/'
}

# Get the generated commit message
COMMIT_MESSAGE=$(generate_commit_message "$LANGUAGES")

# If no commit message is generated, exit
if [ -z "$COMMIT_MESSAGE" ]; then
    echo "Unable to generate commit message."
    exit 1
fi

echo "Commit complete with message: "
echo " "
echo "$COMMIT_MESSAGE"

echo "Do you want to continue commit? (Y/N)"
read answer

if [ "$answer" == "Y" ] || [ "$answer" == "y" ]; then
    # Add changes to the staging area
    git add .

    # Commit the changes
    git commit -m "$COMMIT_MESSAGE"
else
    echo "Exiting the script."
    exit 0
fi