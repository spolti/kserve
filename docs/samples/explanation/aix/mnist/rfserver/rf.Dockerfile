FROM python:3.14.0a2

COPY . .
RUN pip install --no-cache-dir --upgrade pip && pip install --no-cache-dir kserve
RUN pip install --no-cache-dir -e .
ENTRYPOINT ["python", "-m", "rfserver", "--model_name", "aixserver"]
