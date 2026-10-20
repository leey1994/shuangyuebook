// Legado（原版阅读）JS 运行时兼容层 —— JS 侧实现。
//
// 目标：让书源脚本里的 `Packages.java.*` / `javax.crypto.*` / `android.util.Base64`
// / `cn.hutool.*` / `org.jsoup.*` 与 Rhino 下的真实 Java 类行为一致，
// 从而"原版能跑的书源脚本，爽阅也能跑"。
//
// 约定：字节数组 = JS Array<number>（0..255）；二进制跨桥一律 base64。
// 重活走 `__lgcall('jcompat', …)`（见 java_compat.dart），轻活在本地实现。
const String kJavaCompatShim = r'''
(function (g) {
  var U8e = g.__lgUtf8Encode, U8d = g.__lgUtf8Decode;

  // ================= 基础工具 =================
  function bridge(op, o) {
    o = o || {};
    o.op = op;
    var r = __lgcall('jcompat', o);
    if (r && r.e) throw new Error(r.e);
    return r === null || r === undefined ? null : r.v;
  }
  var B64A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64enc(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i] & 0xff;
      var has1 = i + 1 < bytes.length, has2 = i + 2 < bytes.length;
      var b1 = has1 ? bytes[i + 1] & 0xff : 0;
      var b2 = has2 ? bytes[i + 2] & 0xff : 0;
      s += B64A.charAt(b0 >> 2);
      s += B64A.charAt(((b0 & 3) << 4) | (b1 >> 4));
      s += has1 ? B64A.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
      s += has2 ? B64A.charAt(b2 & 63) : '=';
    }
    return s;
  }
  function b64dec(str) {
    var s = String(str === null || str === undefined ? '' : str)
      .replace(/[^A-Za-z0-9+/=]/g, '');
    if (s.indexOf('-') >= 0 || s.indexOf('_') >= 0) {
      s = s.replace(/-/g, '+').replace(/_/g, '/');
    }
    var out = [], bits = 0, val = 0;
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i);
      if (ch === '=') break;
      var idx = B64A.indexOf(ch);
      if (idx < 0) continue;
      val = (val << 6) | idx;
      bits += 6;
      if (bits >= 8) { bits -= 8; out.push((val >> bits) & 0xff); }
    }
    return out;
  }
  // 任意输入 → 字节数组
  function arr(x) {
    if (x === null || x === undefined) return [];
    if (typeof x === 'string') return U8e(x);
    if (typeof x.length === 'number') {
      var o = [];
      for (var i = 0; i < x.length; i++) o.push(x[i] & 0xff);
      return o;
    }
    return [];
  }
  // 字符串按字符集编码成字节；数组原样
  function toBytes(x, cs) {
    if (typeof x === 'string') {
      if (!cs || /^utf-?8$/i.test(String(cs))) return U8e(x);
      return b64dec(bridge('toBytes', { text: x, cs: String(cs) }));
    }
    return arr(x);
  }
  // 字节按字符集解码成字符串
  function toStr(x, cs) {
    if (typeof x === 'string') return x;
    var b = arr(x);
    if (!cs || /^utf-?8$/i.test(String(cs))) return U8d(b);
    return bridge('fromBytes', { data: b64enc(b), cs: String(cs) });
  }
  function hexOf(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) {
      var h = (bytes[i] & 0xff).toString(16);
      s += h.length < 2 ? '0' + h : h;
    }
    return s;
  }
  function unhex(s) {
    var t = String(s === null || s === undefined ? '' : s).replace(/[^0-9a-fA-F]/g, '');
    var o = [];
    for (var i = 0; i + 1 < t.length; i += 2) o.push(parseInt(t.substr(i, 2), 16));
    return o;
  }
  function def(v, d) { return v === null || v === undefined || v === '' ? d : v; }

  // ================= BigInteger =================
  var BIG = typeof BigInt === 'function';
  function parseBig(v, radix) {
    if (!BIG) return null;
    var s = String(v).trim(), neg = false, i = 0;
    if (s.charAt(0) === '-') { neg = true; i = 1; }
    else if (s.charAt(0) === '+') { i = 1; }
    var r = BigInt(radix || 10), acc = BigInt(0);
    var digits = '0123456789abcdefghijklmnopqrstuvwxyz';
    for (; i < s.length; i++) {
      var d = digits.indexOf(s.charAt(i).toLowerCase());
      if (d < 0 || d >= Number(r)) continue;
      acc = acc * r + BigInt(d);
    }
    return neg ? -acc : acc;
  }
  function bytesToBig(b) {
    if (!b.length) return BigInt(0);
    var neg = (b[0] & 0x80) !== 0, x = BigInt(0);
    for (var i = 0; i < b.length; i++) x = (x << BigInt(8)) | BigInt(b[i] & 0xff);
    if (neg) x -= (BigInt(1) << BigInt(b.length * 8));
    return x;
  }
  function bigToBytes(x) {
    if (x === BigInt(0)) return [0];
    var neg = x < BigInt(0);
    if (neg) x = -x;
    var out = [];
    while (x > BigInt(0)) { out.unshift(Number(x & BigInt(255))); x = x >> BigInt(8); }
    if (out[0] & 0x80) out.unshift(0);
    if (neg) {
      for (var i = 0; i < out.length; i++) out[i] = (~out[i]) & 0xff;
      var carry = 1;
      for (var j = out.length - 1; j >= 0; j--) {
        var s = out[j] + carry; out[j] = s & 0xff; carry = s >> 8;
      }
      if (!(out[0] & 0x80)) out.unshift(0xff);
    }
    return out;
  }
  function BigInteger(v, radix) {
    if (!(this instanceof BigInteger)) {
      if (typeof v === 'string') return parseBig(v, radix);
      if (typeof v === 'number') return BigInt(Math.trunc(v));
      return bytesToBig(arr(v));
    }
    if (v === null || v === undefined) { this.__v = BigInt(0); return; }
    if (typeof v === 'bigint') { this.__v = v; return; }
    if (typeof v === 'number') { this.__v = BigInt(Math.trunc(v)); return; }
    if (typeof v === 'string') { this.__v = parseBig(v, radix); return; }
    this.__v = bytesToBig(arr(v));
  }
  BigInteger.prototype = {
    add: function (o) { return new BigInteger(this.__v + big(o)); },
    subtract: function (o) { return new BigInteger(this.__v - big(o)); },
    multiply: function (o) { return new BigInteger(this.__v * big(o)); },
    divide: function (o) { return new BigInteger(this.__v / big(o)); },
    remainder: function (o) { return new BigInteger(this.__v % big(o)); },
    mod: function (o) { var m = big(o), r = this.__v % m; return new BigInteger(r < BigInt(0) ? r + m : r); },
    pow: function (n) { return new BigInteger(this.__v ** BigInt(n)); },
    modPow: function (e, m) {
      var b = big(e), m2 = big(m), base = this.__v % m2;
      if (base < BigInt(0)) base += m2;
      var r = BigInt(1), bb = base;
      while (b > BigInt(0)) {
        if (b & BigInt(1)) r = (r * bb) % m2;
        bb = (bb * bb) % m2;
        b = b >> BigInt(1);
      }
      return new BigInteger(r);
    },
    modInverse: function (m) {
      var a = this.mod(m).__v, m2 = big(m), x0 = BigInt(0), x1 = BigInt(1);
      if (m2 === BigInt(1)) return new BigInteger(BigInt(0));
      while (a > BigInt(1)) {
        var q = a / m2, t = m2;
        m2 = a % m2; a = t;
        t = x0; x0 = x1 - q * x0; x1 = t;
      }
      return new BigInteger(x1 < BigInt(0) ? x1 + big(m) : x1);
    },
    abs: function () { return new BigInteger(this.__v < BigInt(0) ? -this.__v : this.__v); },
    negate: function () { return new BigInteger(-this.__v); },
    and: function (o) { return new BigInteger(this.__v & big(o)); },
    or: function (o) { return new BigInteger(this.__v | big(o)); },
    xor: function (o) { return new BigInteger(this.__v ^ big(o)); },
    not: function () { return new BigInteger(~this.__v); },
    andNot: function (o) { return new BigInteger(this.__v & ~big(o)); },
    shiftLeft: function (n) { return new BigInteger(this.__v << BigInt(n)); },
    shiftRight: function (n) { return new BigInteger(this.__v >> BigInt(n)); },
    testBit: function (n) { return ((this.__v >> BigInt(n)) & BigInt(1)) !== BigInt(0); },
    signum: function () { return this.__v === BigInt(0) ? 0 : (this.__v < BigInt(0) ? -1 : 1); },
    bitLength: function () {
      var x = this.__v < BigInt(0) ? -this.__v : this.__v, n = 0;
      while (x > BigInt(0)) { x = x >> BigInt(1); n++; }
      return n;
    },
    compareTo: function (o) { var b = this.__v - big(o); return b === BigInt(0) ? 0 : (b < BigInt(0) ? -1 : 1); },
    equals: function (o) { try { return this.__v === big(o); } catch (e) { return false; } },
    intValue: function () { return Number(BigInt.asIntN(32, this.__v)); },
    longValue: function () { return Number(BigInt.asIntN(64, this.__v)); },
    doubleValue: function () { return Number(this.__v); },
    floatValue: function () { return Number(this.__v); },
    byteValue: function () { return Number(BigInt.asIntN(8, this.__v)); },
    gcd: function (o) {
      var a = this.__v < BigInt(0) ? -this.__v : this.__v, b = Math.abs0 ? 0 : 0;
      var m = big(o); if (m < BigInt(0)) m = -m;
      while (m !== BigInt(0)) { var t = m; m = a % m; a = t; }
      return new BigInteger(a);
    },
    toByteArray: function () { return bigToBytes(this.__v); },
    toString: function (radix) { return this.__v.toString(radix || 10); },
    toJSON: function () { return this.__v.toString(); }
  };
  function big(o) {
    if (o && o.__v !== undefined) return o.__v;
    if (typeof o === 'bigint') return o;
    if (typeof o === 'number') return BigInt(Math.trunc(o));
    if (typeof o === 'string') return parseBig(o, 10);
    return bytesToBig(arr(o));
  }
  BigInteger.ONE = new BigInteger(BigInt(1));
  BigInteger.ZERO = new BigInteger(BigInt(0));
  BigInteger.TEN = new BigInteger(BigInt(10));
  BigInteger.TWO = new BigInteger(BigInt(2));
  BigInteger.valueOf = function (n) { return new BigInteger(BigInt(Math.trunc(Number(n)))); };
  BigInteger.fromBytes = function (b) { return new BigInteger(b); };

  // ================= MessageDigest / SecureRandom / Mac =================
  function normAlg(a) {
    var s = String(a === null || a === undefined ? 'MD5' : a).toUpperCase().replace(/[_]/g, '-');
    if (s === 'SHA1') return 'SHA-1';
    if (s === 'SHA256') return 'SHA-256';
    if (s === 'SHA512') return 'SHA-512';
    if (s === 'SHA224') return 'SHA-224';
    if (s === 'SHA384') return 'SHA-384';
    return s;
  }
  function MessageDigest(alg) { this.__alg = normAlg(alg); this.__buf = []; }
  MessageDigest.getInstance = function (alg) { return new MessageDigest(alg); };
  MessageDigest.prototype = {
    update: function (b) { var a = toBytes(b); for (var i = 0; i < a.length; i++) this.__buf.push(a[i]); return this; },
    digest: function (b) {
      if (b !== undefined && b !== null) this.update(b);
      var out = b64dec(bridge('digest', { alg: this.__alg, data: b64enc(this.__buf) }));
      this.__buf = [];
      return out;
    },
    reset: function () { this.__buf = []; return this; },
    getAlgorithm: function () { return this.__alg; },
    getDigestLength: function () { return 0; }
  };
  function SecureRandom() { this.__seed = []; }
  SecureRandom.prototype = {
    nextBytes: function (b) {
      var r = b64dec(bridge('random', { n: Math.max(16, arr(b).length || 16) }));
      if (b && typeof b.length === 'number') {
        for (var i = 0; i < b.length; i++) b[i] = r[i % r.length] & 0xff;
      }
      return b;
    },
    nextInt: function (n) {
      var a = b64dec(bridge('random', { n: 4 }));
      var v = ((a[0] << 24) | (a[1] << 16) | (a[2] << 8) | a[3]) >>> 0;
      return n ? v % n : v;
    },
    setSeed: function (s) { this.__seed.push(s); },
    generateSeed: function (n) { return b64dec(bridge('random', { n: n || 8 })); }
  };
  function Mac(alg) { this.__alg = String(alg || 'HmacMD5'); this.__key = []; }
  Mac.getInstance = function (a) { return new Mac(a); };
  Mac.prototype = {
    init: function (key) {
      this.__key = key && key.__key ? arr(key.__key) : toBytes(key);
      return this;
    },
    update: function (b) {
      var a = toBytes(b);
      this.__buf = (this.__buf || []).concat(a);
      return this;
    },
    doFinal: function (b) {
      var data = (this.__buf || []).concat(b === undefined || b === null ? [] : toBytes(b));
      this.__buf = [];
      return b64dec(bridge('hmac', { alg: this.__alg, key: b64enc(this.__key), data: b64enc(data) }));
    },
    getAlgorithm: function () { return this.__alg; }
  };

  // ================= javax.crypto.spec / Cipher =================
  function SecretKeySpec(bytes, alg) { this.__key = toBytes(bytes); this.__alg = alg || 'AES'; }
  SecretKeySpec.prototype.getEncoded = function () { return this.__key.slice(0); };
  SecretKeySpec.prototype.getAlgorithm = function () { return this.__alg; };
  function IvParameterSpec(bytes) { this.__iv = toBytes(bytes); }
  IvParameterSpec.prototype.getIV = function () { return this.__iv.slice(0); };
  function GCMParameterSpec(tag, iv) { this.__iv = toBytes(iv); this.__tag = tag || 128; }
  GCMParameterSpec.prototype.getIV = function () { return this.__iv.slice(0); };
  GCMParameterSpec.prototype.getTLen = function () { return this.__tag; };
  function PBEKeySpec() { }

  function Cipher(trans) {
    this.__t = String(trans || 'AES');
    if (this.__t.indexOf('/') < 0) this.__t += '/ECB/PKCS5Padding';
    this.__mode = 0;
    this.__key = [];
    this.__iv = null;
    this.__aad = null;
  }
  Cipher.ENCRYPT_MODE = 1;
  Cipher.DECRYPT_MODE = 2;
  Cipher.WRAP_MODE = 3;
  Cipher.UNWRAP_MODE = 4;
  Cipher.getInstance = function (t) { return new Cipher(t); };
  Cipher.prototype = {
    init: function (mode, key, spec) {
      this.__mode = (mode === 2 || mode === Cipher.DECRYPT_MODE) ? 2 : 1;
      if (key && key.__key !== undefined) this.__key = arr(key.__key);
      else this.__key = toBytes(key);
      this.__iv = null;
      this.__aad = null;
      if (spec) {
        if (spec.__iv) this.__iv = arr(spec.__iv);
        else if (spec.__tag !== undefined && spec.__tlen !== undefined) this.__iv = arr(spec.__iv);
        else if (typeof spec.length === 'number') this.__iv = arr(spec);
      }
      return this;
    },
    updateAAD: function (aad) { this.__aad = toBytes(aad); },
    update: function (data) {
      this.__buf = (this.__buf || []).concat(toBytes(data));
      return [];
    },
    doFinal: function (data) {
      var input = (this.__buf || []).concat(data === undefined || data === null ? [] : toBytes(data));
      this.__buf = [];
      return b64dec(bridge('cipher', {
        trans: this.__t,
        enc: this.__mode !== 2,
        key: b64enc(this.__key),
        iv: this.__iv === null ? null : b64enc(this.__iv),
        aad: this.__aad === null ? null : b64enc(this.__aad),
        data: b64enc(input)
      }));
    },
    getIV: function () { return this.__iv || []; },
    getAlgorithm: function () { return this.__t.split('/')[0]; },
    getBlockSize: function () { return 16; }
  };

  // ================= java.nio =================
  function ByteBuffer(cap) {
    this.__b = [];
    this.__pos = 0;
    for (var i = 0; i < (cap || 0); i++) this.__b.push(0);
  }
  ByteBuffer.allocate = function (n) { return new ByteBuffer(n); };
  ByteBuffer.wrap = function (b) { var x = new ByteBuffer(0); x.__b = arr(b); return x; };
  ByteBuffer.prototype = {
    put: function (a, off, len) {
      if (typeof a === 'number') { this.__b[this.__pos++] = a & 0xff; return this; }
      var src = toBytes(a);
      var o = off || 0, n = len === undefined ? src.length : len;
      for (var i = 0; i < n; i++) this.__b[this.__pos++] = src[o + i] & 0xff;
      return this;
    },
    array: function () { return this.__b.slice(0); },
    flip: function () { this.__lim = this.__pos; this.__pos = 0; return this; },
    position: function (p) { if (p === undefined) return this.__pos; this.__pos = p; return this; },
    limit: function (p) { if (p === undefined) return this.__lim === undefined ? this.__b.length : this.__lim; this.__lim = p; return this; },
    remaining: function () { return this.limit() - this.__pos; },
    hasRemaining: function () { return this.remaining() > 0; },
    get: function (a, off, len) { return this.put(a, off, len); },
    order: function () { return this; },
    toString: function () { return toStr(this.__b); },
    __isBytes: true
  };

  function Charset(name) { this.__n = String(name || 'UTF-8'); }
  Charset.forName = function (n) { return new Charset(n); };
  Charset.defaultCharset = function () { return new Charset('UTF-8'); };
  Charset.isSupported = function () { return true; };
  Charset.prototype = {
    name: function () { return this.__n; },
    displayName: function () { return this.__n; },
    decode: function (bb) { return toStr(bb && bb.__isBytes ? bb.__b : bb, this.__n); },
    encode: function (s) { return ByteBuffer.wrap(toBytes(String(s), this.__n)); },
    toString: function () { return this.__n; }
  };

  // ================= java.io =================
  function ByteArrayOutputStream() { this.__b = []; }
  ByteArrayOutputStream.prototype = {
    write: function (x, off, len) {
      if (typeof x === 'number') { this.__b.push(x & 0xff); return; }
      var a = toBytes(x), o = off || 0, n = len === undefined ? a.length : len;
      for (var i = 0; i < n; i++) this.__b.push(a[o + i] & 0xff);
    },
    writeBytes: function (x) { this.write(x); },
    toByteArray: function () { return this.__b.slice(0); },
    size: function () { return this.__b.length; },
    reset: function () { this.__b = []; },
    toString: function (cs) { return toStr(this.__b, cs); },
    flush: function () { },
    close: function () { }
  };
  function ByteArrayInputStream(bytes) { this.__b = arr(bytes); this.__p = 0; }
  ByteArrayInputStream.prototype = {
    read: function (x, off, len) {
      if (typeof x === 'number') return this.__p < this.__b.length ? this.__b[this.__p++] : -1;
      if (x && typeof x.length === 'number') {
        var n = 0, o = off || 0, lim = len === undefined ? x.length - o : len;
        while (n < lim && this.__p < this.__b.length) { x[o + n] = this.__b[this.__p++]; n++; }
        return n === 0 ? -1 : n;
      }
      return this.read();
    },
    available: function () { return this.__b.length - this.__p; },
    close: function () { },
    skip: function (n) { this.__p += n; return n; }
  };
  // BufferedReader(InputStreamReader(stream)) —— 只取行文本
  function InputStreamReader(stream, cs) { this.__s = stream; this.__cs = cs; }
  InputStreamReader.prototype.read = function () { return this.__s.read(); };
  InputStreamReader.prototype.close = function () { if (this.__s && this.__s.close) this.__s.close(); };
  function BufferedReader(reader) {
    this.__r = reader;
    var all = [];
    try {
      var b = reader && reader.__s ? reader.__s : reader;
      var off = 0, buf = new Array(8192), n;
      while ((n = b.read(buf, 0, buf.length)) > 0) {
        for (var i = 0; i < n; i++) all.push(buf[i]);
      }
    } catch (e) { }
    this.__lines = toStr(all).split(/\r?\n/);
    this.__i = 0;
  }
  BufferedReader.prototype = {
    readLine: function () { return this.__i < this.__lines.length ? this.__lines[this.__i++] : null; },
    ready: function () { return this.__i < this.__lines.length; },
    close: function () { },
    lines: function () { return this.__lines.slice(this.__i); }
  };

  // ================= java.util.zip =================
  function Inflater(nowrap) { this.__nowrap = nowrap === true; this.__in = null; this.__out = null; this.__done = false; }
  Inflater.prototype = {
    setInput: function (b, off, len) {
      var a = toBytes(b);
      this.__in = off || len ? a.slice(off || 0, (off || 0) + (len === undefined ? a.length : len)) : a;
      this.__out = null;
      this.__done = false;
    },
    inflate: function (out) {
      if (this.__out === null) {
        this.__out = b64dec(bridge('inflate', { data: b64enc(this.__in || []), nowrap: this.__nowrap }));
      }
      if (!out || typeof out.length !== 'number') { this.__done = true; return this.__out; }
      var n = Math.min(out.length, this.__out.length);
      for (var i = 0; i < n; i++) out[i] = this.__out[i] & 0xff;
      this.__out = this.__out.slice(n);
      if (this.__out.length === 0) this.__done = true;
      return n;
    },
    finished: function () { return this.__done || this.__out !== null && this.__out.length === 0; },
    getRemaining: function () { return 0; },
    reset: function () { this.__out = null; this.__done = false; },
    end: function () { }
  };
  function Deflater(nowrap) { this.__nowrap = nowrap === true; }
  Deflater.prototype = {
    setInput: function (b) { this.__in = toBytes(b); },
    deflate: function (out) {
      var r = b64dec(bridge('deflate', { data: b64enc(this.__in || []), nowrap: this.__nowrap }));
      if (!out || typeof out.length !== 'number') return r;
      var n = Math.min(out.length, r.length);
      for (var i = 0; i < n; i++) out[i] = r[i] & 0xff;
      return n;
    },
    finish: function () { }, finished: function () { return true; }, end: function () { }
  };
  function GZIPInputStream(stream) {
    var all = [], b = stream;
    try {
      if (b && b.__b) all = b.__b.slice(b.__p || 0);
      else {
        var buf = new Array(8192), n;
        while ((n = b.read(buf, 0, buf.length)) > 0) {
          for (var i = 0; i < n; i++) all.push(buf[i]);
        }
      }
    } catch (e) { }
    this.__b = b64dec(bridge('gunzip', { data: b64enc(all) }));
    this.__p = 0;
  }
  GZIPInputStream.prototype = new ByteArrayInputStream([]);
  GZIPInputStream.prototype.constructor = GZIPInputStream;

  // ================= java.util 杂项 =================
  function Arrays() { }
  Arrays.copyOf = function (a, n) {
    var s = toBytes(a), o = new Array(n);
    for (var i = 0; i < n; i++) o[i] = i < s.length ? s[i] : 0;
    return o;
  };
  Arrays.copyOfRange = function (a, from, to) {
    var s = toBytes(a), o = [];
    for (var i = from; i < to; i++) o.push(i < s.length ? s[i] : 0);
    return o;
  };
  Arrays.equals = function (a, b) {
    var x = toBytes(a), y = toBytes(b);
    if (x.length !== y.length) return false;
    for (var i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
    return true;
  };
  Arrays.fill = function (a, v) { for (var i = 0; i < a.length; i++) a[i] = v; return a; };
  Arrays.sort = function (a, fn) { return a.sort(fn); };
  Arrays.toString = function (a) { return '[' + toBytes(a).join(', ') + ']'; };
  Arrays.asList = function () {
    var o = [];
    for (var i = 0; i < arguments.length; i++) o.push(arguments[i]);
    return o;
  };
  Arrays.hashCode = function (a) { var h = 1, s = toBytes(a); for (var i = 0; i < s.length; i++) h = (31 * h + s[i]) | 0; return h; };

  function HashMap() { this.__m = {}; this.__k = []; }
  HashMap.prototype = {
    put: function (k, v) { var kk = String(k); if (!(kk in this.__m)) this.__k.push(kk); this.__m[kk] = v; return v; },
    get: function (k) { var kk = String(k); return kk in this.__m ? this.__m[kk] : null; },
    getOrDefault: function (k, d) { var kk = String(k); return kk in this.__m ? this.__m[kk] : d; },
    containsKey: function (k) { return String(k) in this.__m; },
    containsValue: function (v) { for (var k in this.__m) if (this.__m[k] === v) return true; return false; },
    remove: function (k) { var kk = String(k), v = this.__m[kk]; delete this.__m[kk]; return v; },
    keySet: function () { return this.__k.slice(0); },
    values: function () { var o = []; for (var i = 0; i < this.__k.length; i++) o.push(this.__m[this.__k[i]]); return o; },
    entrySet: function () {
      var o = [];
      for (var i = 0; i < this.__k.length; i++) o.push({ key: this.__k[i], value: this.__m[this.__k[i]], getKey: function () { return this.key; }, getValue: function () { return this.value; } });
      return o;
    },
    size: function () { return this.__k.length; },
    isEmpty: function () { return this.__k.length === 0; },
    clear: function () { this.__m = {}; this.__k = []; },
    putAll: function (o) { for (var k in o) this.put(k, o[k]); }
  };
  function UUID(hi, lo) { this.__s = hi; }
  UUID.randomUUID = function () {
    var b = b64dec(bridge('random', { n: 16 }));
    var h = hexOf(b);
    return new UUID(h.substr(0, 8) + '-' + h.substr(8, 4) + '-4' + h.substr(13, 3) + '-a' + h.substr(17, 3) + '-' + h.substr(20, 12));
  };
  UUID.fromString = function (s) { return new UUID(String(s)); };
  UUID.prototype.toString = function () { return this.__s; };
  function JRandom(seed) { this.__s = seed || 1; }
  JRandom.prototype = {
    nextInt: function (n) { this.__s = (this.__s * 1103515245 + 12345) & 0x7fffffff; return n ? this.__s % n : this.__s; },
    nextBytes: function (b) { for (var i = 0; i < b.length; i++) b[i] = this.nextInt(256); },
    nextDouble: function () { return this.nextInt(1000000) / 1000000; }
  };
  function Calendar() { this.__d = new Date(); }
  Calendar.getInstance = function () { return new Calendar(); };
  Calendar.YEAR = 1; Calendar.MONTH = 2; Calendar.DAY_OF_MONTH = 5;
  Calendar.HOUR_OF_DAY = 11; Calendar.MINUTE = 12; Calendar.SECOND = 13;
  Calendar.MILLISECOND = 14; Calendar.DAY_OF_WEEK = 7;
  Calendar.prototype = {
    get: function (f) {
      var d = this.__d;
      switch (f) {
        case 1: return d.getFullYear();
        case 2: return d.getMonth();
        case 5: return d.getDate();
        case 11: return d.getHours();
        case 12: return d.getMinutes();
        case 13: return d.getSeconds();
        case 14: return d.getMilliseconds();
        case 7: return d.getDay() + 1;
      }
      return 0;
    },
    getTimeInMillis: function () { return this.__d.getTime(); },
    setTimeInMillis: function (t) { this.__d = new Date(t); },
    getTime: function () { return this.__d; },
    add: function (f, n) {
      if (f === 1) this.__d.setFullYear(this.__d.getFullYear() + n);
      else if (f === 5) this.__d.setDate(this.__d.getDate() + n);
      else if (f === 12) this.__d.setMinutes(this.__d.getMinutes() + n);
      return this;
    }
  };
  function Objects() { }
  Objects.isNull = function (o) { return o === null || o === undefined; };
  Objects.nonNull = function (o) { return o !== null && o !== undefined; };
  Objects.toString = function (o, d) { return o === null || o === undefined ? def(d, 'null') : String(o); };
  Objects.equals = function (a, b) { return a === b; };
  Objects.requireNonNull = function (o) { if (o === null || o === undefined) throw new Error('NPE'); return o; };

  // ================= java.lang =================
  // java.lang.String 的构造语义：String(byte[], charset) 按字符集解码。
  function JavaString(x, cs) {
    var s;
    if (x === null || x === undefined) s = '';
    else if (typeof x === 'string') s = x;
    else s = toStr(x, cs);
    // `new String(…)` 返回真正的 String 对象（JSON/拼接/toString 均为字符串）
    if (this instanceof JavaString) return new String(s);
    return s;
  }
  JavaString.prototype = { toString: function () { return ''; } };
  JavaString.valueOf = function (o) { return String(o); };
  function System() { }
  System.currentTimeMillis = function () { return Date.now(); };
  System.nanoTime = function () { return Date.now() * 1000000; };
  System.arraycopy = function (src, sp, dst, dp, len) {
    var a = toBytes(src);
    for (var i = 0; i < len; i++) dst[dp + i] = a[sp + i] & 0xff;
  };
  System.gc = function () { };
  System.getProperty = function (k) { return k === 'line.separator' ? '\n' : ''; };
  System.getenv = function (k) { return ''; };
  System.exit = function () { };
  System.out = { println: function (s) { try { java.log(s); } catch (e) { } }, print: function (s) { try { java.log(s); } catch (e) { } } };
  System.err = System.out;
  function Integer(v) { this.__v = Number(v) | 0; }
  Integer.parseInt = function (s, radix) {
    var t = String(s).trim();
    var n = parseInt(t, radix || 10);
    if (isNaN(n)) throw new Error('NumberFormatException: ' + s);
    return n;
  };
  Integer.valueOf = function (v) { return Integer.parseInt(v, 10); };
  Integer.toHexString = function (v) { return (v >>> 0).toString(16); };
  Integer.toBinaryString = function (v) { return (v >>> 0).toString(2); };
  Integer.MAX_VALUE = 2147483647; Integer.MIN_VALUE = -2147483648;
  Integer.toString = function (v, r) { return Number(v).toString(r || 10); };
  function Long(v) { this.__v = Number(v); }
  Long.parseLong = Integer.parseInt;
  Long.valueOf = Integer.parseInt;
  Long.MAX_VALUE = 9007199254740991; Long.MIN_VALUE = -9007199254740991;
  Long.toHexString = function (v) { return Number(v).toString(16); };
  function Double(v) { this.__v = Number(v); }
  Double.parseDouble = function (s) { return Number(s); };
  Double.valueOf = function (s) { return Number(s); };
  function JBoolean(v) { this.__v = !!v; }
  JBoolean.parseBoolean = function (s) { return String(s) === 'true'; };
  JBoolean.valueOf = function (s) { return String(s) === 'true'; };
  JBoolean.TRUE = true; JBoolean.FALSE = false;
  function Character(c) { this.__c = c; }
  Character.isDigit = function (c) { return /[0-9]/.test(String(c)); };
  Character.isLetter = function (c) { return /[a-zA-Z]/.test(String(c)); };
  Character.isLetterOrDigit = function (c) { return /[a-zA-Z0-9]/.test(String(c)); };
  Character.isWhitespace = function (c) { return /\s/.test(String(c)); };
  Character.toUpperCase = function (c) { return String(c).toUpperCase(); };
  Character.toLowerCase = function (c) { return String(c).toLowerCase(); };
  function StringBuilder() { this.__s = ''; }
  StringBuilder.prototype = {
    append: function (x) { this.__s += (x === null || x === undefined ? 'null' : String(x)); return this; },
    toString: function () { return this.__s; },
    length: function () { return this.__s.length; },
    reverse: function () { this.__s = this.__s.split('').reverse().join(''); return this; },
    insert: function (i, x) { this.__s = this.__s.slice(0, i) + String(x) + this.__s.slice(i); return this; },
    deleteCharAt: function (i) { this.__s = this.__s.slice(0, i) + this.__s.slice(i + 1); return this; }
  };
  function Thread() { }
  Thread.sleep = function () { };
  Thread.currentThread = function () { return { getName: function () { return 'main'; }, getId: function () { return 1; } }; };
  Thread.prototype.start = function () { };
  Thread.prototype.run = function () { };

  // ================= java.net =================
  function HttpURLConnection(url) { this.__u = String(url); this.__h = {}; }
  HttpURLConnection.prototype = {
    setRequestProperty: function (k, v) { this.__h[String(k)] = v; return this; },
    addRequestProperty: function (k, v) { this.__h[String(k)] = v; return this; },
    setConnectTimeout: function () { return this; },
    setReadTimeout: function () { return this; },
    setRequestMethod: function () { return this; },
    connect: function () { },
    disconnect: function () { },
    getHeaderField: function (k) { return null; },
    getContentLength: function () { return -1; },
    getResponseCode: function () { return 200; },
    getResponseMessage: function () { return 'OK'; },
    getInputStream: function () {
      var body = java.ajax(this.__u);
      return new ByteArrayInputStream(U8e(String(body === null || body === undefined ? '' : body)));
    },
    getErrorStream: function () { return this.getInputStream(); },
    getOutputStream: function () { return new ByteArrayOutputStream(); }
  };
  function URL(u) { this.__u = String(u); }
  URL.prototype = {
    toString: function () { return this.__u; },
    toExternalForm: function () { return this.__u; },
    getHost: function () { var m = this.__u.match(/^https?:\/\/([^\/:]+)/); return m ? m[1] : ''; },
    getPath: function () { var m = this.__u.match(/^https?:\/\/[^\/]+(\/[^?#]*)/); return m ? m[1] : ''; },
    getQuery: function () { var m = this.__u.match(/\?([^#]*)/); return m ? m[1] : ''; },
    openConnection: function () { return new HttpURLConnection(this.__u); },
    openStream: function () { return new HttpURLConnection(this.__u).getInputStream(); }
  };
  var URLEncoder = {
    encode: function (s, enc) {
      var e = enc || 'UTF-8';
      var bytes = toBytes(String(s), e);
      var out = '';
      for (var i = 0; i < bytes.length; i++) {
        var b = bytes[i];
        if ((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) ||
            b === 0x2d || b === 0x2e || b === 0x5f || b === 0x2a) out += String.fromCharCode(b);
        else if (b === 0x20) out += '+';
        else out += '%' + (b < 16 ? '0' : '') + b.toString(16).toUpperCase();
      }
      return out;
    }
  };
  var URLDecoder = {
    decode: function (s, enc) {
      var t = String(s).replace(/\+/g, ' ');
      var out = [];
      for (var i = 0; i < t.length; i++) {
        if (t.charAt(i) === '%' && i + 2 < t.length) {
          out.push(parseInt(t.substr(i + 1, 2), 16));
          i += 2;
        } else out.push(t.charCodeAt(i) & 0xff);
      }
      return toStr(out, enc || 'UTF-8');
    }
  };
  function URI(u) { this.__u = String(u); }
  URI.create = function (u) { return new URI(u); };
  URI.prototype.toString = function () { return this.__u; };

  // ================= android / hutool / jsoup =================
  var AndroidBase64 = {
    DEFAULT: 0, NO_PADDING: 1, NO_WRAP: 2, CRLF: 4, URL_SAFE: 8, NO_CLOSE: 16,
    decode: function (s, flags) {
      var t = String(s === null || s === undefined ? '' : s);
      if ((flags || 0) & 8) t = t.replace(/-/g, '+').replace(/_/g, '/');
      return b64dec(t);
    },
    encode: function (b, flags) {
      var s = b64enc(toBytes(b));
      if (!((flags || 0) & 1)) { /* 默认带 padding */ } else s = s.replace(/=+$/, '');
      if ((flags || 0) & 8) s = s.replace(/\+/g, '-').replace(/\//g, '_');
      if (!((flags || 0) & 2)) s += '';
      return s;
    },
    encodeToString: function (b, flags) { return AndroidBase64.encode(b, flags); }
  };
  var HexUtil = {
    encodeHex: function (b) { return hexOf(toBytes(b)); },
    encodeHexStr: function (b) { return hexOf(toBytes(b)); },
    decodeHex: function (s) { return unhex(s); }
  };
  var DigestUtil = {
    md5Hex: function (s) { return hexOf(b64dec(bridge('digest', { alg: 'MD5', data: b64enc(toBytes(String(s))) }))); },
    sha1Hex: function (s) { return hexOf(b64dec(bridge('digest', { alg: 'SHA-1', data: b64enc(toBytes(String(s))) }))); },
    sha256Hex: function (s) { return hexOf(b64dec(bridge('digest', { alg: 'SHA-256', data: b64enc(toBytes(String(s))) }))); },
    md5: function (s) { return b64dec(bridge('digest', { alg: 'MD5', data: b64enc(toBytes(String(s))) })); }
  };
  var HutoolBase64 = {
    encode: function (b) { return b64enc(toBytes(b)); },
    decode: function (s) { return b64dec(String(s)); },
    encodeUrlSafe: function (b) { return b64enc(toBytes(b)).replace(/\+/g, '-').replace(/\//g, '_'); },
    decodeStr: function (s, cs) { return toStr(b64dec(String(s)), cs); }
  };

  // jsoup：解析与选择交给宿主（java_compat.dart 用 package:html 实现）
  function wrapNode(n) {
    return {
      __n: n,
      html: function () { return n.html; },
      outerHtml: function () { return n.html; },
      text: function () { return n.text; },
      attr: function (k) { return n.attrs && n.attrs[String(k)] !== undefined ? n.attrs[String(k)] : ''; },
      hasAttr: function (k) { return !!(n.attrs && n.attrs[String(k)] !== undefined); },
      select: function (css) { return selectIn(n.html, css); },
      selectFirst: function (css) { var r = selectIn(n.html, css); return r.length ? r[0] : null; },
      getElementsByTag: function (t) { return selectIn(n.html, String(t)); },
      getElementById: function (id) { return selectIn(n.html, '#' + String(id))[0] || null; },
      children: function () { return []; },
      childNodes: function () { return []; },
      childrenSize: function () { return 0; },
      parent: function () { return null; },
      nextElementSibling: function () { return null; },
      previousElementSibling: function () { return null; },
      id: function () { return n.attrs && n.attrs.id ? n.attrs.id : ''; },
      className: function () { return n.attrs && n.attrs['class'] ? n.attrs['class'] : ''; },
      tagName: function () { return n.tag || 'div'; },
      val: function () { return n.attrs && n.attrs.value ? n.attrs.value : ''; },
      toString: function () { return n.html; }
    };
  }
  function selectIn(html, css) {
    var list = bridge('selector', { html: String(html === null || html === undefined ? '' : html), css: String(css) }) || [];
    var out = [];
    for (var i = 0; i < list.length; i++) out.push(wrapNode(list[i]));
    out.size = function () { return out.length; };
    out.get = function (i) { return out[i]; };
    out.first = function () { return out[0] || null; };
    out.last = function () { return out[out.length - 1] || null; };
    out.text = function () { var s = []; for (var i = 0; i < out.length; i++) s.push(out[i].text()); return s.join(' '); };
    out.attr = function (k) { return out.length ? out[0].attr(k) : ''; };
    out.html = function () { return out.length ? out[0].html() : ''; };
    out.eachText = function () { var s = []; for (var i = 0; i < out.length; i++) s.push(out[i].text()); return s; };
    out.eachAttr = function (k) { var s = []; for (var i = 0; i < out.length; i++) s.push(out[i].attr(k)); return s; };
    out.select = function (css) { return selectIn(out.length ? out[0].html() : '', css); };
    out.is = function () { return out.length > 0; };
    return out;
  }
  function JsoupDocument(html) { this.__h = String(html === null || html === undefined ? '' : html); }
  JsoupDocument.prototype = {
    select: function (css) { return selectIn(this.__h, css); },
    selectFirst: function (css) { var r = selectIn(this.__h, css); return r[0] || null; },
    getElementById: function (id) { return selectIn(this.__h, '#' + id)[0] || null; },
    getElementsByTag: function (t) { return selectIn(this.__h, String(t)); },
    text: function () { return bridge('selector', { html: this.__h, css: 'html', mode: 'text' }) || ''; },
    html: function () { return this.__h; },
    body: function () { return new JsoupDocument(this.__h); },
    title: function () { var r = selectIn(this.__h, 'title'); return r.length ? r[0].text() : ''; },
    location: function () { return ''; },
    toString: function () { return this.__h; }
  };
  var Jsoup = {
    parse: function (html) { return new JsoupDocument(html); },
    parseBodyFragment: function (html) { return new JsoupDocument(html); },
    connect: function (url) {
      var u = String(url), hdrs = {}, body = null, method = 'GET';
      var req = {
        url: u,
        header: function (k, v) { if (v === undefined) return hdrs[k]; hdrs[k] = v; return req; },
        userAgent: function (v) { hdrs['User-Agent'] = v; return req; },
        referrer: function (v) { hdrs['Referer'] = v; return req; },
        cookie: function (k, v) { hdrs['Cookie'] = k + '=' + v; return req; },
        data: function () { return req; },
        method: function (m) { method = m; return req; },
        postDataCharset: function () { return req; },
        timeout: function () { return req; },
        ignoreContentType: function () { return req; },
        ignoreHttpErrors: function () { return req; },
        followRedirects: function () { return req; },
        validateTLSCertificates: function () { return req; },
        execute: function () { return new JsoupResponse(Jsoup.get(u, hdrs)); },
        get: function () { return new JsoupDocument(Jsoup.get(u, hdrs)); },
        post: function () { return new JsoupDocument(Jsoup.get(u, hdrs)); }
      };
      return req;
    },
    get: function (u, hdrs) {
      var d = __lgcall('ajax', { url: String(u) });
      if (d && d.suspend) __lgsusp(d);
      return d && d.v !== null && d.v !== undefined ? d.v : '';
    }
  };
  function JsoupResponse(body) { this.__b = String(body === null || body === undefined ? '' : body); }
  JsoupResponse.prototype = {
    body: function () { return this.__b; },
    text: function () { return this.__b; },
    statusCode: function () { return 200; },
    header: function () { return null; },
    parse: function () { return new JsoupDocument(this.__b); },
    charset: function () { return 'UTF-8'; },
    toString: function () { return this.__b; }
  };

  // ================= 组装 Packages =================
  var root = {};
  function ns(path, obj) {
    var parts = String(path).split('.'), cur = root;
    for (var i = 0; i < parts.length; i++) {
      var k = parts[i];
      if (!cur[k]) cur[k] = {};
      cur = cur[k];
    }
    for (var name in obj) cur[name] = obj[name];
    return root;
  }
  ns('java.lang', {
    String: JavaString, System: System, StringBuilder: StringBuilder,
    Integer: Integer, Long: Long, Double: Double, Boolean: JBoolean,
    Character: Character, Thread: Thread, Math: Math, Object: Object,
    Exception: Error, RuntimeException: Error, Throwable: Error
  });
  ns('java.util', {
    Base64: {
      getDecoder: function () { return { decode: function (v) { return typeof v === 'string' ? b64dec(v) : b64dec(toStr(v)); } }; },
      getEncoder: function () {
        return {
          encode: function (b) { return ByteBuffer.wrap(U8e(b64enc(toBytes(b)))); },
          encodeToString: function (b) { return b64enc(toBytes(b)); },
          withoutPadding: function () { return this; }
        };
      },
      getUrlDecoder: function () { return { decode: function (v) { return b64dec(String(typeof v === 'string' ? v : toStr(v)).replace(/-/g, '+').replace(/_/g, '/')); } }; },
      getUrlEncoder: function () { return { encodeToString: function (b) { return b64enc(toBytes(b)).replace(/\+/g, '-').replace(/\//g, '_'); } }; },
      getMimeDecoder: function () { return { decode: function (v) { return b64dec(typeof v === 'string' ? v : toStr(v)); } }; },
      getMimeEncoder: function () { return { encodeToString: function (b) { return b64enc(toBytes(b)); } }; }
    },
    Arrays: Arrays, HashMap: HashMap, UUID: UUID, Random: JRandom,
    Calendar: Calendar, Objects: Objects, ArrayList: Array, List: Array,
    LinkedList: Array, HashSet: HashMap, LinkedHashMap: HashMap,
    Collections: {
      emptyList: function () { return []; }, emptyMap: function () { return {}; },
      singletonList: function (x) { return [x]; }, unmodifiableList: function (x) { return x; },
      sort: function (a, f) { return a.sort(f); }, reverse: function (a) { return a.reverse(); },
      shuffle: function (a) { return a; }
    },
    zip: { Inflater: Inflater, Deflater: Deflater, GZIPInputStream: GZIPInputStream, InflaterInputStream: GZIPInputStream }
  });
  ns('java.math', { BigInteger: BigInteger, BigDecimal: BigInteger, RoundingMode: {} });
  ns('java.security', {
    MessageDigest: MessageDigest, SecureRandom: SecureRandom,
    KeyPairGenerator: { getInstance: function () { return { initialize: function () { }, genKeyPair: function () { throw new Error('KeyPairGenerator 未实现'); } }; } },
    Signature: { getInstance: function () { return { initSign: function () { }, update: function () { }, sign: function () { throw new Error('Signature 未实现'); } }; } }
  });
  ns('java.nio', { ByteBuffer: ByteBuffer, CharBuffer: { wrap: function (s) { return { toString: function () { return String(s); } }; } } });
  ns('java.nio.charset', {
    Charset: Charset,
    StandardCharsets: {
      UTF_8: new Charset('UTF-8'), ISO_8859_1: new Charset('ISO-8859-1'),
      US_ASCII: new Charset('US-ASCII'), GBK: new Charset('GBK')
    }
  });
  ns('java.io', {
    ByteArrayOutputStream: ByteArrayOutputStream, ByteArrayInputStream: ByteArrayInputStream,
    BufferedReader: BufferedReader, InputStreamReader: InputStreamReader,
    File: function (p) { this.__p = String(p); }, FileOutputStream: ByteArrayOutputStream,
    PrintStream: ByteArrayOutputStream, IOException: Error, EOFException: Error
  });
  ns('java.net', { URL: URL, URI: URI, URLEncoder: URLEncoder, URLDecoder: URLDecoder, HttpURLConnection: HttpURLConnection });
  ns('javax.crypto', {
    Cipher: Cipher, Mac: Mac, KeyGenerator: { getInstance: function () { return { init: function () { }, generateKey: function () { throw new Error('KeyGenerator 未实现'); } }; } },
    spec: {
      SecretKeySpec: SecretKeySpec, IvParameterSpec: IvParameterSpec,
      GCMParameterSpec: GCMParameterSpec, PBEKeySpec: PBEKeySpec, DESKeySpec: g.DESKeySpec
    }
  });
  ns('android.util', { Base64: AndroidBase64, Log: { d: function () { return 0; }, i: function () { return 0; }, e: function () { return 0; }, w: function () { return 0; } } });
  ns('android.text', {
    TextUtils: {
      isEmpty: function (s) { return s === null || s === undefined || String(s).length === 0; },
      join: function (d, a) { return (a || []).join(d); }
    }
  });
  ns('cn.hutool.core.util', { HexUtil: HexUtil, StrUtil: { isBlank: function (s) { return !s || !String(s).trim(); }, format: function (f) { return String(f); } } });
  ns('cn.hutool.core.codec', { Base64: HutoolBase64 });
  ns('cn.hutool.crypto.digest', { DigestUtil: DigestUtil });
  ns('org.jsoup', { Jsoup: Jsoup });
  ns('org.jsoup.nodes', { Document: JsoupDocument, Element: JsoupDocument, Elements: Array });

  // 兼容写法：`Packages.java.util.Base64` / `java.util.Base64` / 直接 `Base64`
  g.Packages = root;
  g.JavaImporter = function () {
    var o = { importPackage: function () { }, importClass: function (c) { return c; } };
    for (var k in root) o[k] = root[k];
    return o;
  };
  try {
    g.importPackage = function () { };
    g.importClass = function (c) { return c; };
  } catch (e) { }
  // 部分书源省略 `Packages.` 前缀（Rhino 下 `java.util.x` 不成立，但写法存在）
  if (g.java) {
    for (var kk in root) { if (g.java[kk] === undefined) g.java[kk] = root[kk]; }
  }
  g.__lgJava = root;
  g.__lgBits = { b64enc: b64enc, b64dec: b64dec, toBytes: toBytes, toStr: toStr, hexOf: hexOf, unhex: unhex };
})(this);
''';
