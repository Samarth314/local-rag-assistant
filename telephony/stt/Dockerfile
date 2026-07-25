# NVIDIA Parakeet ASR service.
#
# HEAVY by nature: NeMo pulls in torch and the model is ~600M parameters.
# It is a SEPARATE image from the Asterisk container on purpose -- telephony
# stays thin and a model reload can never wedge the call path.
#
# On a Jetson, override the base with an L4T/NeMo image that has CUDA-enabled
# torch for aarch64, e.g.:
#   --build-arg BASE_IMAGE=dustynv/nemo:r36.4.0
# The default below is CPU-only and will work anywhere, just slower.
ARG BASE_IMAGE=python:3.11-slim
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    HF_HOME=/models \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg libsndfile1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY telephony/stt/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY telephony/stt/server.py /app/server.py

# Model weights land here; mount a volume so they survive rebuilds.
VOLUME ["/models"]
EXPOSE 8091

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8081"]
