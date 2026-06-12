using System.Runtime.InteropServices;
using System.Text;
using Max.Core;

namespace Max.Windows.Platform;

/// <summary>
/// ISecretStore backed by the Windows Credential Manager (DPAPI-encrypted at rest),
/// the Windows analog of the macOS Keychain. Targets are namespaced "Max/&lt;key&gt;".
/// </summary>
public sealed class CredentialSecretStore : ISecretStore
{
    private const string Prefix = "Max/";
    private const int CRED_TYPE_GENERIC = 1;
    private const int CRED_PERSIST_LOCAL_MACHINE = 2;

    public string? Get(string key)
    {
        if (!CredRead(Prefix + key, CRED_TYPE_GENERIC, 0, out var handle)) return null;
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(handle);
            if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0) return "";
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, (int)cred.CredentialBlobSize);
            return Encoding.Unicode.GetString(bytes);
        }
        finally { CredFree(handle); }
    }

    public void Set(string key, string value)
    {
        var blob = Encoding.Unicode.GetBytes(value);
        var blobPtr = Marshal.AllocHGlobal(blob.Length);
        try
        {
            Marshal.Copy(blob, 0, blobPtr, blob.Length);
            var cred = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = Prefix + key,
                CredentialBlob = blobPtr,
                CredentialBlobSize = (uint)blob.Length,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = Environment.UserName,
            };
            if (!CredWrite(ref cred, 0))
                throw new InvalidOperationException($"CredWrite failed: {Marshal.GetLastWin32Error()}");
        }
        finally { Marshal.FreeHGlobal(blobPtr); }
    }

    public void Delete(string key) => CredDelete(Prefix + key, CRED_TYPE_GENERIC, 0);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CredReadW")]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CredWriteW")]
    private static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CredDeleteW")]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
