FROM python:3.12-slim

WORKDIR /app

COPY requirements-docker.txt .
RUN pip install --no-cache-dir -r requirements-docker.txt

COPY *.py ./

# Run as a non-root user; index/state live on the /data volume.
RUN useradd -m rag && mkdir /data && chown rag:rag /data
USER rag
ENV RAG_DATA_DIR=/data

CMD ["python", "cli.py"]
