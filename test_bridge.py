from ghost_bindings import ingest_intent

def main():
    intent = "User must be admin to delete"
    print(f"[*] Sending intent to Ghost Matrix: '{intent}'")
    try:
        response = ingest_intent(intent)
        print(f"[*] Received response from Ghost Matrix: '{response}'")
        print("[+] SUCCESS: Memory-safe cross-substrate handshake completed.")
    except Exception as e:
        print(f"[-] FAILED: {e}")

if __name__ == "__main__":
    main()
