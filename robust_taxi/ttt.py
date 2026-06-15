import os
from pymongo import MongoClient

# MONGO_URI = "mongodb+srv://taxi_user:taxi@taxidb.ed4tqft.mongodb.net/?appName=TaxiDB"
# client = MongoClient(MONGO_URI)
client = MongoClient(os.environ["MONGODB_URI"])
print(client.list_database_names())




