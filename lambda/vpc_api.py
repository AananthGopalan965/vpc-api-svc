import json
import boto3
import ipaddress
import os
import math
from botocore.exceptions import ClientError

# Environment variables (set in Lambda or API Gateway)
DYNAMODB_TABLE = os.environ.get("DYNAMODB_TABLE")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(DYNAMODB_TABLE)
ec2 = boto3.client("ec2")

def lambda_handler(event, context):
    print(f"Event: {json.dumps(event)}")
    try:
        user_email = event["requestContext"]["authorizer"]["claims"]["email"]
        print(f"User email: {user_email}")
        print(f"Authorizer: {json.dumps(event['requestContext']['authorizer'])}")

        # Route requests based on action
        if event["resource"] == "/vpcs" and event["httpMethod"] == "POST":
            return create_vpc(event["body"], user_email)
        elif event["resource"] == "/vpcs" and event["httpMethod"] == "GET":
            return get_vpcs(event["queryStringParameters"])
        else:
            return {"statusCode": 400, "body": json.dumps({"message": "Invalid request"})}

    except Exception as e:
        print(f"Error: {e}")
        return {"statusCode": 500, "body": json.dumps({"message": str(e)})}

def create_vpc(body_json, user_email):
    print(f"Creating VPC for user: {user_email}")
    body = json.loads(body_json)
    cidr_block = body.get("cidr_block")
    region = body.get("region")
    print(f"Received CIDR: {cidr_block}, Region: {region}")

    if not cidr_block or not region:
        return {"statusCode": 400, "body": json.dumps({"message": "Missing CIDR or region"})}

    if not is_private_cidr(cidr_block):
        return {"statusCode": 400, "body": json.dumps({"message": "CIDR is not a private IP range"})}

    if vpc_exists(cidr_block):
        return {"statusCode": 409, "body": json.dumps({"message": "VPC with this CIDR already exists", "vpc_id": vpc_exists(cidr_block)})}

    try:
        ec2_region = boto3.client("ec2", region_name=region)
        vpc = ec2_region.create_vpc(CidrBlock=cidr_block, InstanceTenancy="dedicated")
        vpc_id = vpc["Vpc"]["VpcId"]

        # Enable DNS support and hostnames
        ec2_region.modify_vpc_attribute(VpcId=vpc_id, EnableDnsSupport={'Value': True})
        ec2_region.modify_vpc_attribute(VpcId=vpc_id, EnableDnsHostnames={'Value': True})

        # Get Availability Zones
        azs = ec2_region.describe_availability_zones(Filters=[{'Name': 'region-name', 'Values': [region]}])
        az_names = [az['ZoneName'] for az in azs['AvailabilityZones']]

        # Create subnets
        subnets = create_subnets(ec2_region, vpc_id, cidr_block, az_names)
        print(f"Subnets: {subnets}")

        # Create Internet Gateway and NAT Gateway
        igw_id = create_internet_gateway(ec2_region, vpc_id)
        egress_subnet_id = None
        for subnet_name, subnet_id in subnets.items():
            if "egresssubnet" in subnet_name:
                egress_subnet_id = subnet_id
                break  # Stop searching once found

        if egress_subnet_id:
            nat_gateway_id = create_nat_gateway(ec2_region, egress_subnet_id)
        else:
            print("Error: Egress subnet not found.")
            return {"statusCode": 500, "body": json.dumps({"message": "Egress subnet not found."})}


        # Create route tables and associations
        create_route_tables(ec2_region, vpc_id, subnets, igw_id, nat_gateway_id, az_names)

        # Store VPC and user data
        store_vpc_data(vpc_id, cidr_block, region, subnets, user_email)

        return {"statusCode": 201, "body": json.dumps({"vpc_id": vpc_id, "subnets": subnets})}

    except ClientError as e:
        print(f"AWS Error: {e}")
        return {"statusCode": 500, "body": json.dumps({"message": str(e)})}
    except Exception as e:
        print(f"Error: {e}")
        return {"statusCode": 500, "body": json.dumps({"message": str(e)})}

def get_vpcs(query_params):
    try:
        if query_params and "vpc_id" in query_params:
            vpc_id = query_params["vpc_id"]
            response = table.get_item(Key={"vpc_id": vpc_id})
            if "Item" in response:
                return {"statusCode": 200, "body": json.dumps(response["Item"])}
            else:
                return {"statusCode": 404, "body": json.dumps({"message": "VPC not found"})}

        else:
            return {"statusCode": 400, "body": json.dumps({"message": "Provide vpc_id in query parameters"})}

    except Exception as e:
        print(f"Error: {e}")
        return {"statusCode": 500, "body": json.dumps({"message": str(e)})}

def is_private_cidr(cidr):
    try:
        ip_network = ipaddress.ip_network(cidr)
        return ip_network.is_private
    except ValueError:
        return False

def vpc_exists(cidr):
    response = ec2.describe_vpcs(Filters=[{"Name": "cidr-block", "Values": [cidr]}])
    if response["Vpcs"]:
        return response["Vpcs"][0]["VpcId"]
    return False

def create_subnets(ec2_client, vpc_id, cidr_block, az_names):

    ip_network = ipaddress.ip_network(cidr_block)
    subnets = {}

    # Calculate subnet CIDR blocks using ipaddress
    original_prefix_len = ip_network.prefixlen
    original_num_addresses = ip_network.num_addresses
    subnet_num_addresses = original_num_addresses / 4 # Always 4 subnets
    subnet_prefix_len = 32 - int(math.log2(subnet_num_addresses))
    prefix_len_diff = subnet_prefix_len - original_prefix_len
    

    if prefix_len_diff < 0:
        return {"error": "CIDR block too small for desired subnets"}

    subnet_cidr_blocks = [
        str(list(ip_network.subnets(prefixlen_diff=prefix_len_diff))[i])
        for i in range(4)
    ]

    subnet_names = [f"ingresssubnet{az_names[0]}", f"egresssubnet{az_names[1]}", f"privatesubnet{az_names[0]}", f"datasubnet{az_names[1]}"]

    # Create subnets 
    for i in range(len(subnet_names)):
        subnet = ec2_client.create_subnet(
            VpcId=vpc_id,
            CidrBlock=subnet_cidr_blocks[i],
            AvailabilityZone=az_names[i % 2], #Alternate between AZs
            TagSpecifications=[
                {"ResourceType": "subnet", "Tags": [{"Key": "Name", "Value": subnet_names[i]}]}
            ],
        )
        subnets[subnet_names[i]] = subnet["Subnet"]["SubnetId"]

    return subnets
            
    
def create_internet_gateway(ec2_client, vpc_id):
    igw = ec2_client.create_internet_gateway()
    igw_id = igw["InternetGateway"]["InternetGatewayId"]
    ec2_client.attach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)
    return igw_id

def create_nat_gateway(ec2_client, egress_subnet_id):
    elastic_ip = ec2_client.allocate_address(Domain="vpc")
    eip_id = elastic_ip["AllocationId"]
    nat_gateway = ec2_client.create_nat_gateway(SubnetId=egress_subnet_id, AllocationId=eip_id)
    nat_gateway_id = nat_gateway["NatGateway"]["NatGatewayId"]
    ec2_client.get_waiter("nat_gateway_available").wait(NatGatewayIds=[nat_gateway_id])
    return nat_gateway_id

def create_route_tables(ec2_client, vpc_id, subnets, igw_id, nat_gateway_id, az_names):
    # Create public route table
    public_route_table = ec2_client.create_route_table(VpcId=vpc_id)
    public_route_table_id = public_route_table["RouteTable"]["RouteTableId"]
    ec2_client.create_route(RouteTableId=public_route_table_id, DestinationCidrBlock="0.0.0.0/0", GatewayId=igw_id)
    ec2_client.associate_route_table(SubnetId=subnets[f"ingresssubnet{az_names[0]}"], RouteTableId=public_route_table_id)

    # Create private route table
    private_route_table = ec2_client.create_route_table(VpcId=vpc_id)
    private_route_table_id = private_route_table["RouteTable"]["RouteTableId"]
    ec2_client.create_route(RouteTableId=private_route_table_id, DestinationCidrBlock="0.0.0.0/0", NatGatewayId=nat_gateway_id)

    # Associate private route table with private and data subnets
    for az_name in az_names:
        ec2_client.associate_route_table(SubnetId=subnets[f"privatesubnet{az_name}"], RouteTableId=private_route_table_id)
        ec2_client.associate_route_table(SubnetId=subnets[f"datasubnet{az_name}"], RouteTableId=private_route_table_id)

    return None

def store_vpc_data(vpc_id, cidr_block, region, subnets, user_email):
    item = {
        "vpc_id": vpc_id,
        "cidr_block": cidr_block,
        "region": region,
        "subnets": subnets,
        "user_email": user_email
    }
    table.put_item(Item=item)