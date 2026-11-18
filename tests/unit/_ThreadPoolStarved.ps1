# STORE-CALL-SLOW-1: a .NET thread pool with no free thread, and an HTTP
# service that does not need one.
#
# The Functions PowerShell worker runs each call in a runspace that holds a
# thread-pool thread until the call ends. A store request that waits on a
# Task (SendAsync(...).GetAwaiter().GetResult()) needs ANOTHER thread-pool
# thread to finish that Task. When none is free, the request waits until the
# pool adds a thread. MEASURED on this computer: about 500 ms a call, the same
# as the lab install's store calls.
#
# VmfPoolStarver holds every thread the pool may have (it lowers the pool's
# limit to its minimum and fills it), so the pool cannot add one until
# Release, which a dedicated thread calls after HoldMs. A store request that
# needs the pool therefore takes at least HoldMs; one that does not, a few ms.
#
# VmfThreadServer answers every request with 200 and a small body, from
# dedicated threads (no thread-pool thread), so it keeps answering while the
# pool has no free thread. _FakeBlobService.ps1 cannot: HttpListener answers
# from the pool.
#
# VmfTlsServer is the same service over TLS, with a self-signed certificate
# made when it starts, and VmfTlsAccept.Any the certificate check that
# accepts it (a .NET method: a script block cannot run on the thread that
# checks a certificate). The run store is reached over TLS, and TLS is where
# the second wait was (STORE-CALL-SLOW-1, the lab result of 2026-11-08).
#
# Not named *.Tests.ps1 on purpose: Pester discovers only test files.

if (-not ('VmfPoolStarver' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class VmfPoolStarver
{
    static readonly object gate = new object();
    static ManualResetEventSlim held;
    static int maxWorker, maxIo, started;

    // Fills the pool. Returns false (and holds nothing) if the pool would not
    // take the lower limit.
    public static bool Starve(int holdMs)
    {
        lock (gate)
        {
            if (held != null) { throw new InvalidOperationException("already starved"); }
            int minWorker, minIo;
            ThreadPool.GetMinThreads(out minWorker, out minIo);
            ThreadPool.GetMaxThreads(out maxWorker, out maxIo);
            if (!ThreadPool.SetMaxThreads(minWorker, maxIo)) { return false; }
            held = new ManualResetEventSlim(false);
            started = 0;
            var wait = held;
            // More blockers than the limit: the extra ones wait in the queue,
            // ahead of any work queued later.
            for (int i = 0; i < minWorker + 4; i++)
            {
                ThreadPool.UnsafeQueueUserWorkItem(_ => { Interlocked.Increment(ref started); wait.Wait(); }, null);
            }
            var release = new Thread(() => { Thread.Sleep(holdMs); Release(); });
            release.IsBackground = true;
            release.Start();
            return true;
        }
    }

    public static int Started { get { return Volatile.Read(ref started); } }

    // Other service calls starting all the time: a new thread-pool work item
    // every everyMs that holds its thread holdMs, from a dedicated thread,
    // until StopChurn. This is how the pool runs short in the Functions worker
    // without ever being fully held.
    static volatile bool churning;
    public static void Churn(int everyMs, int holdMs)
    {
        churning = true;
        var t = new Thread(() => { while (churning) { ThreadPool.UnsafeQueueUserWorkItem(_ => Thread.Sleep(holdMs), null); Thread.Sleep(everyMs); } });
        t.IsBackground = true;
        t.Start();
    }
    public static void StopChurn() { churning = false; }

    // True when a work item queued now does not run within ms.
    public static bool IsStarved(int ms)
    {
        var probe = new ManualResetEventSlim(false);
        ThreadPool.UnsafeQueueUserWorkItem(_ => probe.Set(), null);
        return !probe.Wait(ms);
    }

    public static void Release()
    {
        lock (gate)
        {
            if (held == null) { return; }
            held.Set();
            held = null;
            ThreadPool.SetMaxThreads(maxWorker, maxIo);
        }
    }
}

public class VmfThreadServer : IDisposable
{
    readonly TcpListener listener;
    volatile bool stopping;
    public int Requests;
    public string BaseUri { get; private set; }

    public VmfThreadServer()
    {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        BaseUri = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/";
        var accept = new Thread(Accept);
        accept.IsBackground = true;
        accept.Start();
    }

    void Accept()
    {
        while (!stopping)
        {
            TcpClient c;
            try { c = listener.AcceptTcpClient(); } catch { return; }
            var t = new Thread(() => Serve(c));
            t.IsBackground = true;
            t.Start();
        }
    }

    static string ReadLine(Stream s)
    {
        var sb = new StringBuilder();
        while (true)
        {
            int b = s.ReadByte();
            if (b < 0) { return null; }
            if (b == 10) { return sb.ToString().TrimEnd((char)13); }
            sb.Append((char)b);
        }
    }

    void Serve(TcpClient c)
    {
        try
        {
            c.NoDelay = true;
            var s = c.GetStream();
            while (!stopping)
            {
                string first = ReadLine(s);
                if (string.IsNullOrEmpty(first)) { return; }
                bool head = first.StartsWith("HEAD ", StringComparison.Ordinal);
                int length = 0;
                string line;
                while (!string.IsNullOrEmpty(line = ReadLine(s)))
                {
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) { length = int.Parse(line.Substring(15).Trim()); }
                }
                if (line == null) { return; }
                var body = new byte[length];
                int got = 0;
                while (got < length) { int n = s.Read(body, got, length - got); if (n <= 0) { return; } got += n; }
                Interlocked.Increment(ref Requests);
                byte[] payload = Encoding.UTF8.GetBytes("{\"n\":1}");
                string headers = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nETag: \"0x1\"\r\nContent-Length: " + payload.Length + "\r\n\r\n";
                byte[] h = Encoding.ASCII.GetBytes(headers);
                s.Write(h, 0, h.Length);
                if (!head) { s.Write(payload, 0, payload.Length); }
                s.Flush();
            }
        }
        catch { }
        finally { try { c.Close(); } catch { } }
    }

    public void Dispose()
    {
        stopping = true;
        try { listener.Stop(); } catch { }
    }
}
'@
}

if (-not ('VmfTlsServer' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

public class VmfTlsServer : IDisposable
{
    readonly TcpListener listener;
    readonly X509Certificate2 cert;
    volatile bool stopping;
    public int Requests;
    public int Connections;
    public string BaseUri { get; private set; }

    public VmfTlsServer()
    {
        using (var rsa = RSA.Create(2048))
        {
            var req = new CertificateRequest("CN=localhost", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            var san = new SubjectAlternativeNameBuilder(); san.AddDnsName("localhost"); req.CertificateExtensions.Add(san.Build());
            using (var c = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1)))
            {
                // Windows TLS needs a key it can use from a store, so the
                // certificate goes out as PFX and back in.
#pragma warning disable SYSLIB0057
                cert = new X509Certificate2(c.Export(X509ContentType.Pfx), (string)null, X509KeyStorageFlags.Exportable);
#pragma warning restore SYSLIB0057
            }
        }
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        BaseUri = "https://localhost:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/";
        var t = new Thread(Accept) { IsBackground = true }; t.Start();
    }

    void Accept()
    {
        while (!stopping)
        {
            TcpClient c;
            try { c = listener.AcceptTcpClient(); } catch { return; }
            Interlocked.Increment(ref Connections);
            var t = new Thread(() => Serve(c)) { IsBackground = true }; t.Start();
        }
    }

    static string ReadLine(Stream s)
    {
        var sb = new StringBuilder();
        while (true) { int b = s.ReadByte(); if (b < 0) return null; if (b == 10) return sb.ToString().TrimEnd((char)13); sb.Append((char)b); }
    }

    void Serve(TcpClient c)
    {
        try
        {
            c.NoDelay = true;
            var ssl = new SslStream(c.GetStream(), false);
            ssl.AuthenticateAsServer(cert, false, false);
            while (!stopping)
            {
                string first = ReadLine(ssl);
                if (string.IsNullOrEmpty(first)) return;
                bool head = first.StartsWith("HEAD ", StringComparison.Ordinal);
                int length = 0; string line;
                while (!string.IsNullOrEmpty(line = ReadLine(ssl)))
                {
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(line.Substring(15).Trim());
                }
                if (line == null) return;
                var body = new byte[length]; int got = 0;
                while (got < length) { int n = ssl.Read(body, got, length - got); if (n <= 0) return; got += n; }
                Interlocked.Increment(ref Requests);
                byte[] payload = Encoding.UTF8.GetBytes("{\"n\":1}");
                byte[] h = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: " + payload.Length + "\r\n\r\n");
                var all = new byte[h.Length + (head ? 0 : payload.Length)];
                Buffer.BlockCopy(h, 0, all, 0, h.Length);
                if (!head) Buffer.BlockCopy(payload, 0, all, h.Length, payload.Length);
                ssl.Write(all, 0, all.Length);
                ssl.Flush();
            }
        }
        catch { }
        finally { try { c.Close(); } catch { } }
    }

    public void Dispose() { stopping = true; try { listener.Stop(); } catch { } }
}

public static class VmfTlsAccept
{
    public static bool Any(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; }
}

"@
}