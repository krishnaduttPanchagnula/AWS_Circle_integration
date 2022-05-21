import gzip
import json
import base64
import boto3
import os

def lambda_handler(event, context):
    logData = str(
                      gzip.decompress(base64.b64decode(
                          event["awslogs"]["data"])), "utf-8"
                  ) 

    jsonBody = json.loads(logData)
    print(jsonBody)


    sns = boto3.client('sns')
    print(os.environ['snsarn'])
    response = sns.publish(TopicArn= str(os.environ['snsarn']),Message = str(jsonBody))

    print(response)


    
   