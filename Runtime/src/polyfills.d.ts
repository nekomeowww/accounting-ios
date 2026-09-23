declare module 'whatwg-fetch' {
  export const Headers: typeof globalThis.Headers;
  export const Request: typeof globalThis.Request;
  export const Response: typeof globalThis.Response;
}
declare module 'blob-polyfill' {
  export const Blob: typeof globalThis.Blob;
  export const File: typeof globalThis.File;
  export const FileReader: typeof globalThis.FileReader;
}
