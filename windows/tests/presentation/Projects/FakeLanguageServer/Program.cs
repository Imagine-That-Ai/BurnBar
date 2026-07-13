using System;
using System.IO;
using System.Text;
using System.Text.Json;

namespace OpenBurnBar.App.Presentation.Tests.FakeLanguageServer;

public static class FakeLanguageServerMarker
{
}

internal static class Program
{
    private static void Main()
    {
        using Stream input = Console.OpenStandardInput();
        using Stream output = Console.OpenStandardOutput();
        while (ReadFrame(input) is { } body)
        {
            using JsonDocument document = JsonDocument.Parse(body);
            JsonElement root = document.RootElement;
            string method = root.TryGetProperty("method", out JsonElement methodElement)
                ? methodElement.GetString() ?? string.Empty
                : string.Empty;
            if (!root.TryGetProperty("id", out JsonElement id))
            {
                if (string.Equals(method, "exit", StringComparison.Ordinal))
                {
                    return;
                }

                continue;
            }

            object result = method switch
            {
                "initialize" => new { capabilities = new { documentSymbolProvider = true, referencesProvider = true } },
                "textDocument/documentSymbol" => new[]
                {
                    new
                    {
                        name = "ExactTarget",
                        kind = 12,
                        range = new
                        {
                            start = new { line = 0, character = 0 },
                            end = new { line = 0, character = 11 },
                        },
                    },
                },
                "textDocument/references" => References(root),
                "shutdown" => new { },
                _ => new { },
            };

            WriteFrame(output, new { jsonrpc = "2.0", id, result });
        }
    }

    private static object[] References(JsonElement root)
    {
        string uri = root.GetProperty("params").GetProperty("textDocument").GetProperty("uri").GetString()!;
        return new object[]
        {
            new
            {
                uri,
                range = new
                {
                    start = new { line = 0, character = 0 },
                    end = new { line = 0, character = 11 },
                },
            },
            new
            {
                uri,
                range = new
                {
                    start = new { line = 2, character = 4 },
                    end = new { line = 2, character = 15 },
                },
            },
        };
    }

    private static byte[]? ReadFrame(Stream input)
    {
        var header = new MemoryStream();
        int previous = -1;
        int beforePrevious = -1;
        while (true)
        {
            int value = input.ReadByte();
            if (value < 0)
            {
                return null;
            }

            header.WriteByte((byte)value);
            if (beforePrevious == '\r' && previous == '\n' && value == '\r')
            {
                int last = input.ReadByte();
                if (last != '\n')
                {
                    return null;
                }

                header.WriteByte((byte)last);
                break;
            }

            beforePrevious = previous;
            previous = value;
        }

        string headerText = Encoding.ASCII.GetString(header.ToArray());
        int separator = headerText.IndexOf(':');
        int contentLength = int.Parse(headerText[(separator + 1)..].Trim().TrimEnd('\r', '\n'));
        byte[] body = new byte[contentLength];
        int offset = 0;
        while (offset < body.Length)
        {
            int read = input.Read(body, offset, body.Length - offset);
            if (read == 0)
            {
                return null;
            }

            offset += read;
        }

        return body;
    }

    private static void WriteFrame(Stream output, object payload)
    {
        byte[] body = JsonSerializer.SerializeToUtf8Bytes(payload);
        byte[] header = Encoding.ASCII.GetBytes($"Content-Length: {body.Length}\r\n\r\n");
        output.Write(header, 0, header.Length);
        output.Write(body, 0, body.Length);
        output.Flush();
    }
}
