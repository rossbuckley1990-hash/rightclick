const OPENAPI = {
  openapi: "3.0.3",
  info: {
    title: "RIGHTCLICK MOAT-002 Durable State Service",
    version: "1.0.0"
  },
  paths: {
    "/records": {
      post: {
        operationId: "createDurableRecord",
        summary: "Create Durable Record",
        requestBody: {
          required: true,
          content: {
            "application/json": {
              schema: {
                type: "object",
                additionalProperties: false,
                required: [
                  "title",
                  "priority"
                ],
                properties: {
                  title: {
                    type: "string"
                  },
                  priority: {
                    type: "string",
                    enum: [
                      "low",
                      "medium",
                      "high"
                    ]
                  }
                }
              }
            }
          }
        },
        responses: {
          "201": {
            description: "Persisted record",
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  additionalProperties: false,
                  required: [
                    "id",
                    "title",
                    "priority"
                  ],
                  properties: {
                    id: {
                      type: "string"
                    },
                    title: {
                      type: "string"
                    },
                    priority: {
                      type: "string",
                      enum: [
                        "low",
                        "medium",
                        "high"
                      ]
                    }
                  }
                }
              }
            }
          }
        }
      }
    },

    "/records/{id}": {
      get: {
        operationId: "readDurableRecord",
        summary: "Read Durable Record",
        parameters: [
          {
            name: "id",
            in: "path",
            required: true,
            schema: {
              type: "string"
            }
          }
        ],
        responses: {
          "200": {
            description: "Persisted record read independently",
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  additionalProperties: false,
                  required: [
                    "id",
                    "title",
                    "priority"
                  ],
                  properties: {
                    id: {
                      type: "string"
                    },
                    title: {
                      type: "string"
                    },
                    priority: {
                      type: "string",
                      enum: [
                        "low",
                        "medium",
                        "high"
                      ]
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
};

function json(value, status = 200) {
  return new Response(
    JSON.stringify(value, null, 2),
    {
      status,
      headers: {
        "content-type": "application/json",
        "cache-control": "no-store"
      }
    }
  );
}

export class RecordStore {
  constructor(state, env) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (
      request.method === "POST" &&
      url.pathname === "/create"
    ) {
      const body = await request.json();

      if (
        typeof body !== "object" ||
        body === null ||
        Array.isArray(body) ||
        typeof body.title !== "string" ||
        body.title.length === 0 ||
        ![
          "low",
          "medium",
          "high"
        ].includes(body.priority)
      ) {
        return json(
          {
            error: "invalid record"
          },
          400
        );
      }

      const id = crypto.randomUUID();

      const record = {
        id,
        title: body.title,
        priority: body.priority
      };

      await this.state.storage.put(
        "record:" + id,
        record
      );

      return json(
        record,
        201
      );
    }

    if (
      request.method === "GET" &&
      url.pathname.startsWith("/record/")
    ) {
      const id =
        decodeURIComponent(
          url.pathname.substring(
            "/record/".length
          )
        );

      const record =
        await this.state.storage.get(
          "record:" + id
        );

      if (!record) {
        return json(
          {
            error: "not found"
          },
          404
        );
      }

      return json(record);
    }

    return new Response(
      "Not found\n",
      {
        status: 404
      }
    );
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (
      request.method === "GET" &&
      url.pathname === "/identity"
    ) {
      return new Response(
        "RIGHTCLICK MOAT-002 DURABLE REMOTE SOFTWARE\n" +
        "Execution location: Cloudflare Workers + Durable Objects\n",
        {
          headers: {
            "content-type": "text/plain",
            "cache-control": "no-store"
          }
        }
      );
    }

    if (
      request.method === "GET" &&
      url.pathname === "/openapi.json"
    ) {
      return json(OPENAPI);
    }

    const objectID =
      env.RECORD_STORE.idFromName(
        "moat-002-record-store"
      );

    const store =
      env.RECORD_STORE.get(
        objectID
      );

    if (
      request.method === "POST" &&
      url.pathname === "/records"
    ) {
      const body =
        await request.text();

      return store.fetch(
        new Request(
          "https://durable.internal/create",
          {
            method: "POST",
            headers: {
              "content-type":
                "application/json"
            },
            body
          }
        )
      );
    }

    if (
      request.method === "GET" &&
      url.pathname.startsWith(
        "/records/"
      )
    ) {
      const id =
        decodeURIComponent(
          url.pathname.substring(
            "/records/".length
          )
        );

      return store.fetch(
        new Request(
          "https://durable.internal/record/" +
          encodeURIComponent(id),
          {
            method: "GET"
          }
        )
      );
    }

    return new Response(
      "Not found\n",
      {
        status: 404
      }
    );
  }
};
