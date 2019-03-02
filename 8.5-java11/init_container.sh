#!/usr/bin/env bash
cat >/etc/motd <<EOL 
  _____                               
  /  _  \ __________ _________   ____  
 /  /_\  \\___   /  |  \_  __ \_/ __ \ 
/    |    \/    /|  |  /|  | \/\  ___/ 
\____|__  /_____ \____/ |__|    \___  >
        \/      \/                  \/ 
A P P   S E R V I C E   O N   L I N U X

Documentation: http://aka.ms/webapp-linux

**NOTE**: No files or system changes outside of /home will persist beyond your application's current session. /home is your application's persistent storage and is shared across all the server instances.


EOL
cat /etc/motd

echo "Setup openrc ..." && openrc && touch /run/openrc/softlevel

echo Starting ssh service...
rc-service sshd start

# Default to CATALINA_BASE=/home/tomcat
if [[ -z $CATALINA_BASE && -a /home/tomcat/conf/server.xml ]]
then
    export CATALINA_BASE=/home/tomcat
fi

# if IGNORE_CATALINA_BASE=1 or true, unset CATALINA_BASE
if [[ "$IGNORE_CATALINA_BASE" = "1" ||  "$IGNORE_CATALINA_BASE" = "true" ]]
then
    echo Setting CATALINA_BASE to empty as IGNORE_CATALINA_BASE is set to $IGNORE_CATALINA_BASE
    export CATALINA_BASE=
fi

if [ ! -d /home/site/wwwroot/webapps ]
then
    mkdir -p /home/site/wwwroot
    cp -r /tmp/tomcat/webapps /home/site/wwwroot
fi

# WEBSITE_INSTANCE_ID will be defined uniquely for each worker instance while running in Azure.
# During development it may not be defined, in that case  we set WEBSITE_INSTNACE_ID=dev.
if [ -z "$WEBSITE_INSTANCE_ID" ]
then
    export WEBSITE_INSTANCE_ID=dev
fi

# BEGIN: Configure App Insights

# Inject App Insights artefcats into Tomcat, if APPINSIGHTS_INSTRUMENTATIONKEY is set to a non-empty value
if [[ ! -z $APPINSIGHTS_INSTRUMENTATIONKEY ]]
then
    echo "Initializing App Insights.."
    export CATALINA_OPTS=-javaagent:/usr/local/app_insights/aiagent/applicationinsights-agent-$AI_VERSION.jar $CATALINA_OPTS
    mv /usr/local/app_insights/tomcat_lib/* /usr/local/tomcat/lib/
    mv /tmp/tomcat/conf/web-easyauth-ai.xml /usr/local/tomcat/conf/web.xml
else
    echo "Skipping App Insights initialization"
fi

# END: Configure App Insights

# BEGIN: Define JAVA OPTIONS

# Configure JAVA OPTIONS. Make sure, we append the default values instead of prepending them.
# That way, the default values take precedence and we avoid the risk of an appsetting overriding the critical (default) properties.

export JAVA_OPTS="$JAVA_OPTS -Djdk.tls.ephemeralDHKeySize=2048"
export JAVA_OPTS="$JAVA_OPTS -Djava.protocol.handler.pkgs=org.apache.catalina.webresources"
export JAVA_OPTS="$JAVA_OPTS -Djava.util.logging.config.file=/usr/local/tomcat/conf/logging.properties"
export JAVA_OPTS="$JAVA_OPTS -Djava.util.logging.manager=org.apache.juli.ClassLoaderLogManager"
export JAVA_OPTS="$JAVA_OPTS -Dsite.logdir=/home/LogFiles"
export JAVA_OPTS="$JAVA_OPTS -Dsite.home=/home"
export JAVA_OPTS="$JAVA_OPTS -Dsite.tempdir=/tmp"
export JAVA_OPTS="$JAVA_OPTS -Dport.http=80"
export JAVA_OPTS="$JAVA_OPTS -noverify"
export JAVA_OPTS="$JAVA_OPTS -Dcatalina.instance.name=$WEBSITE_INSTANCE_ID"

export _JAVA_OPTIONS="$_JAVA_OPTIONS -Djava.net.preferIPv4Stack=true"

# END: Define JAVA OPTIONS

# BEGIN: Configure ~/.profile

# After all env vars are defined, add the ones of interest to ~/.profile
# Adding to ~/.profile makes the env vars available to new login sessions (ssh) of the same user.

# list of variables that will be added to ~/.profile
export_vars=()

# Step 1. Add app settings to ~/.profile
# To check if an environment variable xyz is an app setting, we check if APPSETTING_xyz is defined as an env var
while read -r var
do
    if [ -n "`printenv APPSETTING_$var`" ]
    then
        export_vars+=($var)
    fi
done <<< `printenv | cut -d "=" -f 1 | grep -v ^APPSETTING_`

# Step 2. Add well known environment variables to ~/.profile
well_known_env_vars=( 
    CATALINA_HOME
    CATALINA_BASE
    CATALINA_OPTS
    HTTP_LOGGING_ENABLED
    WEBSITE_SITE_NAME
    WEBSITE_ROLE_INSTANCE_ID
    TOMCAT_VERSION
    JAVA_OPTS
    JAVA_HOME
    JAVA_VERSION
    TOMCAT_MAJOR
    WEBSITE_INSTANCE_ID
    _JAVA_OPTIONS
    TOMCAT_SHA1
    JAVA_ALPINE_VERSION
    JAVA_DEBIAN_VERSION
    AI_VERSION
    )

for var in "${well_known_env_vars[@]}"
do
    if [ -n "`printenv $var`" ]
    then
        export_vars+=($var)
    fi
done

# Step 3. Add environment variables with well known prefixes to ~/.profile
while read -r var
do
    export_vars+=($var)
done <<< `printenv | cut -d "=" -f 1 | grep -E "^(WEBSITE|APPSETTING|SQLCONNSTR|MYSQLCONNSTR|SQLAZURECONNSTR|CUSTOMCONNSTR)_"`

# Write the variables to be exported to ~/.profile
for export_var in "${export_vars[@]}"
do
    echo Exporting env var $export_var
    # We use single quotes to preserve escape characters
	echo export $export_var=\'`printenv $export_var`\' >> ~/.profile
done

# We want all ssh sesions to start in the /home directory
echo "cd /home" >> ~/.profile

# END: Configure ~/.profile

# BEGIN: Process startup file / startup command, if any

DEFAULT_STARTUP_FILE=/home/startup.sh
STARTUP_FILE=
STARTUP_COMMAND=

# The web app can be configured to run a custom startup command or a custom startup script
# This custom command / script will be available to us as a param ($1, $2, ...)
#
# IF $1 is a non-empty string AND an existing file, we treat $1 as a startup file (and ignore $2, $3, ...)
# IF $1 is a non-empty string BUT NOT an existing file, we treat $@ (equivalent of $1, $2, ... combined) as a startup command
# IF $1 is an empty string AND $DEFAULT_STARTUP_FILE exists, we use it as the startup file
# ELSE, we skip running the startup script / command
#
if [ -n "$1" ] # $1 is a non-empty string
then
    if [ -f "$1" ] # $1 file exists
    then
        STARTUP_FILE=$1
    else
        STARTUP_COMMAND=$@
    fi
elif [ -f $DEFAULT_STARTUP_FILE ] # Default startup file path exists
then
    STARTUP_FILE=$DEFAULT_STARTUP_FILE
fi

echo STARTUP_FILE=$STARTUP_FILE
echo STARTUP_COMMAND=$STARTUP_COMMAND

# If $STARTUP_FILE is a non-empty string, we need to run the startup file
# We first fix the EOL characters in it and then run it
if [ -n "$STARTUP_FILE" ]
then
    TMP_STARTUP_FILE=/tmp/startup.sh
    echo Copying $STARTUP_FILE to $TMP_STARTUP_FILE
    # Convert EOL to Unix-style
    cat $STARTUP_FILE | tr '\r' '\n' > $TMP_STARTUP_FILE
    echo Running STARTUP_FILE: $TMP_STARTUP_FILE
    source $TMP_STARTUP_FILE
    echo Finished running startup file $TMP_STARTUP_FILE
else
    echo No STARTUP_FILE available.
fi

if [ -n "$STARTUP_COMMAND" ]
then
    echo Running STARTUP_COMMAND: "$STARTUP_COMMAND"
    $STARTUP_COMMAND
else
    echo No STARTUP_COMMAND defined.
fi

# END: Process startup file / startup command, if any

# Start Tomcat
echo Starting Tomcat with CATALINA_BASE set to \"$CATALINA_BASE\"
catalina.sh run