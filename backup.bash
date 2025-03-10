#!/bin/bash

#set -e  # Exit on error

SCRIPTDIR="$(dirname "$0")"

source $SCRIPTDIR/env_vars.env

if [[ "${DEBUG_IMAGE}" == "true" ]];
then
	# show all the environment variables
	export 
fi


case "$BACKUP_DESTINATION" in
    "aws_s3"|"AWS_S3")
        RESTIC_REPOSITORY="s3:s3.${AWS_DEFAULT_REGION}.amazonaws.com/${AWS_S3_BUCKET}/${CLUSTER_NAME}-${CLUSTER_NAMESPACE}"
        ;;
    "azure_blob"|"AZURE_BLOB")
        RESTIC_REPOSITORY="azure:${AZURE_CONTAINER}:${CLUSTER_NAME}-${CLUSTER_NAMESPACE}"
        ;;
    "google_cloud"|"GOOGLE_CLOUD")
        RESTIC_REPOSITORY="gs:${GCP_BUCKET}/${CLUSTER_NAME}-${CLUSTER_NAMESPACE}"
        ;;
    "generic_s3"|"GENERIC_S3")
	RESTIC_REPOSITORY="s3:${S3_ENDPOINT}/${AWS_S3_BUCKET}/${VALKEY_TYPE}-${VALKEY_NAME}-${VALKEY_NAMESPACE}"
	;;
    *)
        echo "ERROR: Invalid choice. Exiting."
        exit 1
        ;;
esac

echo "INFO: Checking connectivity to the S3 service"
nc -zv ${S3_HOST} ${S3_PORT}
if [ $? == 0 ];
then
	echo "INFO: Successfully accesible: host ${S3_HOST} - port ${S3_PORT}"
else
	echo "ERROR: Service S3 is not accesible: host ${S3_HOST} - port ${S3_PORT}"
fi

#
# setting some connection configurations options
#

opts=""
if [[ "${VALKEY_USE_TLS}" == "true" ]];
then
	if [ ! -d /certs ];
	then
		echo "ERROR: Please mount the certificates into /certs directory"
		exit 1
	fi
	echo "INFO: the service uses TLS"
	opts=$opts" --tls --cacert /certs/ca.crt --cert /certs/tls.crt --key /certs/tls.key"
fi

if [ ! -z ${VALKEY_PASSWORD} ];
then
	echo "INFO: the service uses password authentication"
	opts=$opts" -a ${VALKEY_PASSWORD} --no-auth-warning"
fi


VALKEY_MASTER=0.0.0.0

initialize_repository() {
    # To set the password of the repo you must pass it the env Variable  RESTIC_PASSWORD
    echo "INFO: Initializing from restic the repository"
    if ! restic -r "$RESTIC_REPOSITORY" snapshots &>/dev/null ; then
	set -e
        echo "INFO: Initializing restic repository..."
        restic init --repo "$RESTIC_REPOSITORY"
	set +e
    else
        echo "INFO: Restic repository already initialized."
    fi
}


# This is valid only if this is a single or replication redis
discover_master() {

	echo "INFO: Discovering Valkey Master"
	echo "INFO: Getting ip(s) of the instance: $VALKEY_NAME"

	case "${VALKEY_TYPE}" in

		  "standalone")
			VALKEY_MASTER=$(kubectl get pods -n $VALKEY_NAMESPACE -o wide -l app.kubernetes.io/instance=$VALKEY_NAME | tail -n +2 | awk '{print $6}')
                	echo "INFO: Master found with IP: $VALKEY_MASTER"
		    ;;
		
		  "replication")
			VALKEY_MASTER=$(kubectl get pods -n $VALKEY_NAMESPACE -o wide -l app.kubernetes.io/instance=$VALKEY_NAME,app.kubernetes.io/component=primary | tail -n +2 | awk '{print $6}')
                        echo "INFO: Primary node found with IP: $VALKEY_MASTER"
		    ;;
		
		  "sentinel")
		        VALKEY_MASTER=$(redis-cli -h ${VALKEY_NAME}.${VALKEY_NAMESPACE}.svc  -p 26379 $opts sentinel primary myprimary | grep ${VALKEY_NAME})
			echo "INFO: Primary node found with IP: $VALKEY_MASTER"
		    ;;
		
		  *)
		   	echo "ERROR: not recognized VALKEY_TYPE" 
			exit 1
		    ;;
	esac
}

# Used only by redis standalone and replication
perform_redis_backup() {
	
	echo "INFO: Performing the backup"
	if [[ "${VALKEY_MASTER}" != "0.0.0.0" ]];
	then
		set -e
		echo "INFO: Connecting to the master and performing the backup"
		redis-cli -h ${VALKEY_MASTER} -p ${VALKEY_PORT} $opts --rdb "/tmp/${VALKEY_NAME}.rdb"
		echo "INFO: Saving the data in S3"
		restic -r "$RESTIC_REPOSITORY" backup "/tmp/${VALKEY_NAME}.rdb" --host "${VALKEY_NAME}_${VALKEY_NAMESPACE}" --tag "${VALKEY_NAME}" --tag "valkey"
		rm "/tmp/${VALKEY_NAME}.rdb"
		echo "INFO: Backup completed successfully."
		set +e
	fi

}

#
#
#
# Starting main program
#
#
#

initialize_repository
echo "INFO: Valkey type set: ${VALKEY_TYPE}"
discover_master
perform_redis_backup 
