import Foundation

// MARK: - Wire types

enum ProtobufWireType: UInt8 {
  case varint = 0
  case fixed64 = 1
  case lengthDelimited = 2
  case fixed32 = 5
}

// MARK: - Writer

struct ProtobufWriter {
  private(set) var data = Data()

  mutating func writeVarint(_ value: UInt64) {
    var v = value
    repeat {
      var byte = UInt8(v & 0x7F)
      v >>= 7
      if v != 0 { byte |= 0x80 }
      data.append(byte)
    } while v != 0
  }

  mutating func writeTag(fieldNumber: Int, wireType: ProtobufWireType) {
    writeVarint(UInt64(fieldNumber << 3 | Int(wireType.rawValue)))
  }

  mutating func writeInt32(fieldNumber: Int, _ value: Int32) {
    writeTag(fieldNumber: fieldNumber, wireType: .varint)
    writeVarint(UInt64(bitPattern: Int64(value)))
  }

  mutating func writeInt64(fieldNumber: Int, _ value: Int64) {
    writeTag(fieldNumber: fieldNumber, wireType: .varint)
    writeVarint(UInt64(bitPattern: value))
  }

  mutating func writeBytes(fieldNumber: Int, _ value: Data) {
    writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
    writeVarint(UInt64(value.count))
    data.append(value)
  }

  mutating func writeString(fieldNumber: Int, _ value: String) {
    writeBytes(fieldNumber: fieldNumber, Data(value.utf8))
  }

  mutating func writeMessage(fieldNumber: Int, _ build: (inout ProtobufWriter) -> Void) {
    var nested = ProtobufWriter()
    build(&nested)
    writeBytes(fieldNumber: fieldNumber, nested.data)
  }

  mutating func writeEmptyMessage(fieldNumber: Int) {
    writeMessage(fieldNumber: fieldNumber) { _ in }
  }
}

// MARK: - Reader

struct ProtobufReader {
  private let data: Data
  private var offset = 0

  init(data: Data) { self.data = data }

  var isAtEnd: Bool { offset >= data.count }

  mutating func readTag() throws -> (field: Int, wireType: ProtobufWireType) {
    let key = try readVarint()
    guard let wireType = ProtobufWireType(rawValue: UInt8(key & 0x07)) else {
      throw GPhotosError.protobufDecode("unknown wire type")
    }
    return (Int(key >> 3), wireType)
  }

  mutating func readVarint() throws -> UInt64 {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    for _ in 0..<10 {
      guard offset < data.count else {
        throw GPhotosError.protobufDecode("unexpected end of protobuf")
      }
      let byte = data[data.startIndex + offset]
      offset += 1
      result |= UInt64(byte & 0x7F) << shift
      if byte & 0x80 == 0 { return result }
      shift += 7
    }
    throw GPhotosError.protobufDecode("varint overflow")
  }

  mutating func readInt64() throws -> Int64 {
    Int64(bitPattern: try readVarint())
  }

  mutating func readBytes() throws -> Data {
    let length = try readVarint()
    let start = data.startIndex + offset
    let remaining = data.endIndex - start
    guard length <= UInt64(remaining) else {
      throw GPhotosError.protobufDecode("invalid length-delimited field")
    }
    let end = start + Int(length)
    offset += Int(length)
    return data.subdata(in: start..<end)
  }

  mutating func readString() throws -> String {
    let bytes = try readBytes()
    guard let string = String(data: bytes, encoding: .utf8) else {
      throw GPhotosError.protobufDecode("invalid UTF-8 string")
    }
    return string
  }

  mutating func readFixed(_ count: Int) throws -> Data {
    guard count <= data.count - offset else {
      throw GPhotosError.protobufDecode("unexpected end of protobuf")
    }
    let start = data.startIndex + offset
    offset += count
    return data.subdata(in: start..<start + count)
  }

  mutating func skipField(wireType: ProtobufWireType) throws {
    switch wireType {
    case .varint: _ = try readVarint()
    case .fixed64: try skip(8)
    case .lengthDelimited:
      // Advanced past rather than copied out, as `readBytes` would.
      let length = try readVarint()
      guard length <= UInt64(data.count - offset) else {
        throw GPhotosError.protobufDecode("invalid length-delimited field")
      }
      try skip(Int(length))
    case .fixed32: try skip(4)
    }
  }

  private mutating func skip(_ count: Int) throws {
    guard count <= data.count - offset else {
      throw GPhotosError.protobufDecode("unexpected end of protobuf")
    }
    offset += count
  }
}
