import json
import requests

with open('example.json', 'r') as file:
    data = json.load(file)
    print(data)

    filtered_data = {key: value for key, value in data.items() if not value.get('private', True)}

    url = 'http://example.com/api/data'
    response = requests.post(url, json=filtered_data)

    if response.status_code == 200:
        print('Data sent successfully')
        for key, value in filtered_data.items():
            if value.get('valid', False):
                print(key)
    
    else:
        print('Failed to send data. Status code:', response.status_code)