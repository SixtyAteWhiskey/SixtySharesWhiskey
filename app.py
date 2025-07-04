from flask import Flask, request, jsonify, send_from_directory
from flask_bcrypt import Bcrypt
import os
from datetime import datetime
import ssl

BASE_DIR = os.path.abspath(os.path.dirname(__file__))
UPLOAD_FOLDER = '/srv/sixtyshareswhiskey/uploads'
CHAT_LOG = '/srv/sixtyshareswhiskey/chat.log'
app = Flask(__name__)
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER


##TLS settings
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.maximum_version = ssl.TLSVersion.TLSv1_3
context.set_ciphers("ECDHE+AESGCM:ECDHE+CHACHA20")
context.set_ecdh_curve("prime256v1")
context.options |= ssl.OP_CIPHER_SERVER_PREFERENCE
context.options |= ssl.OP_NO_COMPRESSION
context.load_cert_chain(certfile='/srv/sixtyshareswhiskey/certs/cert.pem', keyfile='/srv/sixtyshareswhiskey/certs/key.pem')


@app.route('/')
def serve_index():
    return send_from_directory('.', 'index.html')

@app.after_request
def add_hsts_header(response):
    response.headers['Strict-Transport-Security'] = 'max-age=63072000; includeSubDomains; preload'
    return response

@app.route('/<path:filename>')
def static_files(filename):
    return send_from_directory(BASE_DIR, filename)

@app.route('/upload', methods=['POST'])
def upload_file():
    if 'file' not in request.files:
        return "No file part", 400
    file = request.files['file']
    if file.filename == '':
        return "No selected file", 400
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    filename = f"{timestamp}_{file.filename}"
    file.save(os.path.join(app.config['UPLOAD_FOLDER'], filename))
    return "Upload successful", 200

@app.route('/uploads')
def list_uploads():
    files = os.listdir(app.config['UPLOAD_FOLDER'])
    links = "\n".join(f'<li><a href="/uploads/{f}">{f}</a></li>' for f in files)
    return f"<ul>{links}</ul>"

@app.route('/uploads/<path:filename>', methods=['GET'])
def serve_upload(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)

@app.route('/chat', methods=['GET'])
def get_chat():
    messages = []
    if os.path.exists(CHAT_LOG):
        with open(CHAT_LOG, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ts, msg = line.split('|||', 1)
                    messages.append({'timestamp': ts, 'message': msg})
                except ValueError:
                    continue
    return jsonify({'messages': messages})

@app.route('/chat', methods=['POST'])
def post_chat():
    msg = request.form.get('message', '').strip()
    if not msg:
        return "Empty message", 400
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = f"{timestamp}|||{msg}\n"
    with open(CHAT_LOG, 'a', encoding='utf-8') as f:
        f.write(entry)
    return "Message received", 200

if __name__ == "__main__":
    app.run(ssl_context=context, host="0.0.0.0", port=5000)
