# Use Node 18 for better performance and modern features
FROM node:18-alpine

# Create app directory
WORKDIR /app

# Install Express
RUN npm init -y && \
    npm install express

# Copy our test app
COPY app.js .

# Set default port (can be overridden)
ENV PORT=3000

# Start the app
CMD ["node", "app.js"]