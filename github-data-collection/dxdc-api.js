/**
 * DX Data Cloud API client - A client for interacting with the DX Data Cloud API
 *
 * This client provides methods for DX Data Cloud API endpoints and handles authentication with API tokens.
 */

/**
 * DXDataCloudClient - A client for interacting with the DX Data Cloud API
 */
export class DXDataCloudClient {
    /**
     * Create a new DXDataCloudClient
     * @param {Object} options - Configuration options
     * @param {string} options.url - Base URL for the API
     * @param {string} options.token - API token for authentication
     */
    constructor(options = {}) {
      this.apiToken = options.token;
      this.baseUrl = options.url;
      this.headers = {
        Accept: "application/json",
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.apiToken}`,
      };
    }
  
    customData = {
      /**
       * Get a custom data entry.
       *
       * @param {string} reference - The domain reference
       * @param {string} key - The domain key
       * @returns {Promise<Object>} - The response from the API
       */
      get: (reference, key) => this.get("/api/customData.get", { reference, key }),
  
      /**
       * Set a custom data entry.
       *
       * @param {string} reference - The domain reference
       * @param {string} key - The domain key
       * @param {Object} value - The value to set
       * @returns {Promise<Object>} - The response from the API
       */
      set: (reference, key, value) => this.post("/api/customData.set", { reference, key, value }),
  
      /**
       * Set multiple custom data entries.
       *
       * @param {Array<{reference: string, key: string, value: Object}>} data - The data to set
       * @returns {Promise<Object>} - The response from the API
       */
      setAll: (payload) => {
        const entries = Array.isArray(payload)
          ? payload
          : (payload && Array.isArray(payload.data) ? payload.data : []);
        return this.post("/api/customData.setAll", { data: entries });
      },
  
      /**
       * Delete a custom data entry.
       *
       * @param {string} reference - The domain reference
       * @param {string} key - The domain key
       * @returns {Promise<Object>} - The response from the API
       */
      delete: (reference, key) => this.post("/api/customData.delete", { reference, key }),
    };
  
    /**
     * Make a GET request
     * @param {string} endpoint - The API endpoint
     * @param {Object} params - Query parameters
     * @returns {Promise<Object>} - The parsed JSON response
     */
    async get(endpoint, params = {}) {
      const queryString =
        Object.keys(params).length > 0 ? `?${objectToQueryString(params)}` : "";
      const url = `${this.baseUrl}${endpoint}${queryString}`;
  
      const response = await fetch(url, {
        method: "GET",
        headers: this.headers,
      });
  
      return processResponse(response, endpoint);
    }
  
    /**
     * Make a POST request
     * @param {string} endpoint - The API endpoint
     * @param {Object} data - The request body
     * @returns {Promise<Object>} - The parsed JSON response
     */
    async post(endpoint, data = {}) {
      const url = `${this.baseUrl}${endpoint}`;
  
      const response = await fetch(url, {
        method: "POST",
        headers: this.headers,
        body: JSON.stringify(data),
      });
  
      return processResponse(response, endpoint);
    }
  
    /**
     * Make a PUT request
     * @param {string} endpoint - The API endpoint
     * @param {Object} data - The request body
     * @returns {Promise<Object>} - The parsed JSON response
     */
    async put(endpoint, data = {}) {
      const url = `${this.baseUrl}${endpoint}`;
  
      const response = await fetch(url, {
        method: "PUT",
        headers: this.headers,
        body: JSON.stringify(data),
      });
  
      return processResponse(response, endpoint);
    }
  }
  
  /**
   * Helper function to convert an object to a query string
   * @param {Object} params - The parameters to convert
   * @returns {string} - The query string
   */
  const objectToQueryString = (params) => {
    return Object.keys(params)
      .filter((key) => params[key] !== undefined && params[key] !== null)
      .map(
        (key) => `${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`
      )
      .join("&");
  };
  
  /**
   * Process the response from a fetch request
   * @param {Response} response - The fetch response
   * @param {string} endpoint - The API endpoint for error reporting
   * @returns {Promise<Object>} - The parsed JSON response
   * @throws {Error} - If the response is not ok
   */
  const processResponse = async (response, endpoint) => {
    if (!response.ok) {
      const error = new Error(`Error fetching ${endpoint}`);
      error.status = response.status;
      error.payload = await response.json().catch(() => null);
      throw error;
    }
    return response.json();
  };
  