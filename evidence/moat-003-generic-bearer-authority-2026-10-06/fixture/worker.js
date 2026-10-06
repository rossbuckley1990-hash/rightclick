
const OPENAPI_JSON = "{\"components\":{\"securitySchemes\":{\"BearerAuth\":{\"scheme\":\"bearer\",\"type\":\"http\"}}},\"info\":{\"title\":\"RIGHTCLICK MOAT-003 Bearer Authority Service\",\"version\":\"1.0.0\"},\"openapi\":\"3.0.3\",\"paths\":{\"/records\":{\"post\":{\"operationId\":\"createSecureRecord\",\"requestBody\":{\"content\":{\"application/json\":{\"schema\":{\"additionalProperties\":false,\"properties\":{\"priority\":{\"enum\":[\"low\",\"medium\",\"high\"],\"type\":\"string\"},\"title\":{\"type\":\"string\"}},\"required\":[\"title\",\"priority\"],\"type\":\"object\"}}},\"required\":true},\"responses\":{\"201\":{\"content\":{\"application/json\":{\"schema\":{\"additionalProperties\":false,\"properties\":{\"id\":{\"type\":\"string\"},\"priority\":{\"enum\":[\"low\",\"medium\",\"high\"],\"type\":\"string\"},\"title\":{\"type\":\"string\"}},\"required\":[\"id\",\"title\",\"priority\"],\"type\":\"object\"}}},\"description\":\"Created\"},\"401\":{\"description\":\"Bearer authority required\"}},\"security\":[{\"BearerAuth\":[]}],\"summary\":\"Create Secure Record\"}}}}";
const EXPECTED_TOKEN_SHA256 = "cbff52984ae99021ee9e1b47e0f0c591962689b22f9b93b5bebdf6d3145c59fc";

async function sha256Hex(value) {
  const bytes =
    new TextEncoder().encode(value);

  const digest =
    await crypto.subtle.digest(
      "SHA-256",
      bytes
    );

  return [...new Uint8Array(digest)]
    .map(
      byte =>
        byte
          .toString(16)
          .padStart(2, "0")
    )
    .join("");
}

function jsonResponse(
  value,
  status = 200
) {
  return new Response(
    JSON.stringify(value),
    {
      status,
      headers: {
        "content-type":
          "application/json",
        "cache-control":
          "no-store",
      },
    }
  );
}

export default {
  async fetch(request) {
    const url =
      new URL(request.url);

    if (
      request.method === "GET" &&
      url.pathname === "/identity"
    ) {
      return new Response(
        "RIGHTCLICK MOAT-003 BEARER AUTHORITY REMOTE SOFTWARE\n",
        {
          status: 200,
          headers: {
            "content-type":
              "text/plain; charset=utf-8",
            "cache-control":
              "no-store",
          },
        }
      );
    }

    if (
      request.method === "GET" &&
      url.pathname === "/openapi.json"
    ) {
      return new Response(
        OPENAPI_JSON,
        {
          status: 200,
          headers: {
            "content-type":
              "application/json",
            "cache-control":
              "no-store",
          },
        }
      );
    }

    if (
      request.method === "POST" &&
      url.pathname === "/records"
    ) {
      const authorization =
        request.headers.get(
          "authorization"
        ) || "";

      if (
        !authorization.startsWith(
          "Bearer "
        )
      ) {
        return jsonResponse(
          {
            error:
              "bearer authority required"
          },
          401
        );
      }

      const token =
        authorization.slice(7);

      const receivedHash =
        await sha256Hex(token);

      if (
        receivedHash !==
        EXPECTED_TOKEN_SHA256
      ) {
        return jsonResponse(
          {
            error:
              "bearer authority rejected"
          },
          401
        );
      }

      let body;

      try {
        body =
          await request.json();
      } catch {
        return jsonResponse(
          {
            error:
              "invalid json"
          },
          400
        );
      }

      return jsonResponse(
        {
          id:
            "moat003-secure-record",
          priority:
            body.priority,
          title:
            body.title,
        },
        201
      );
    }

    return jsonResponse(
      {
        error:
          "not found"
      },
      404
    );
  },
};
