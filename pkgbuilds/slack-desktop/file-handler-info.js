// Linux builds of file-handler-info (github.com/clavin/node-file-handler-info)
// compile src/impl_none.cc, which finds no handler. This is the same result
// without an architecture-specific addon.
exports.getHandlerInfo = (filePath) => {
  if (typeof filePath !== 'string') {
    throw new TypeError('Expected 1st argument to be string');
  }
  return { handlerPath: null, friendlyName: null };
};
