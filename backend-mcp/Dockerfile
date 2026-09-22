# Use an official lightweight Python image
FROM python:3.11-slim

# Set the working directory inside the container
WORKDIR /app

# Copy dependency file and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the source code
COPY src/ src/

# Set Python path so it can find 'src' modules
ENV PYTHONPATH=/app/src

# Expose the port (Cloud Run expects 8080 by default)
ENV PORT=8080

# Command to run the application using uvicorn directly for production stability
# We point it to 'src.main:mcp._app' because FastMCP uses FastAPI under the hood
CMD ["python", "src/main.py"]