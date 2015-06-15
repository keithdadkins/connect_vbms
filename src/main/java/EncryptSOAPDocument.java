import org.apache.ws.security.SOAPConstants;
import org.apache.ws.security.WSEncryptionPart;
import org.apache.ws.security.components.crypto.Crypto;
import org.apache.ws.security.components.crypto.CryptoFactory;
import org.apache.ws.security.message.WSSecEncrypt;
import org.apache.ws.security.message.WSSecHeader;
import org.apache.ws.security.message.WSSecSAMLToken;
import org.apache.ws.security.message.WSSecSignature;
import org.apache.ws.security.message.WSSecTimestamp;
import org.apache.ws.security.util.WSSecurityUtil;
import org.apache.ws.security.util.XMLUtils;
import org.w3c.dom.Document;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.List;
import java.util.Properties;
import java.util.ArrayList;

public class EncryptSOAPDocument
{
  private static final String VBMS_NAMESPACE = "http://vbms.vba.va.gov/external/eDocumentService/v4";
  private static final String SOAP_NAMESPACE = "http://schemas.xmlsoap.org/soap/envelope/";

  public static void main(String[] args)
  {
    if (args.length < 4) {
      printUsage();
      System.exit(1);
    }

    System.setProperty("logfilename", "../log/upload.log");

    String inFileName = args[0];
    String keyFileName = args[1];
    String keyFilePass = args[2];
    String requestName = args[3];

    try
    {
      Properties properties = loadCryptoProperties(keyFileName);

      String document = new String(
        Files.readAllBytes(Paths.get(inFileName)), Charset.defaultCharset()
      );

      Crypto crypto = CryptoFactory.getInstance(properties);

      document = addTimestamp(document);
      document = addSignature(document, crypto, keyFilePass, requestName);
      document = addEncryption(document, crypto, requestName);
      System.out.println(document);
    }
    catch (Exception e)
    {
      e.printStackTrace();
      System.exit(255);
    }
  }

  public static Document getSOAPDoc(String document) throws Exception
  {
    InputStream in = new ByteArrayInputStream(document.getBytes());
    DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
    factory.setNamespaceAware(true);
    DocumentBuilder builder = factory.newDocumentBuilder();
    Document doc = builder.parse(in);
    return doc;
  }

  public static String addTimestamp(String document) throws Exception
  {
    Document doc = getSOAPDoc(document);
    WSSecHeader secHeader = new WSSecHeader();
    secHeader.insertSecurityHeader(doc);
    WSSecTimestamp timestamp = new WSSecTimestamp();
    timestamp.setTimeToLive(300);
    Document createdDoc = timestamp.build(doc, secHeader);
    return XMLUtils.PrettyDocumentToString(createdDoc);
  }

  public static String addSignature(String document, Crypto crypto,
                                    String keypass, String requestType)
                                    throws Exception
  {
    WSSecSignature builder = new WSSecSignature();
    builder.setUserInfo("importkey", keypass);
    Document doc = getSOAPDoc(document);
    SOAPConstants soapConstants = WSSecurityUtil.getSOAPConstants(doc.getDocumentElement());
    WSSecHeader secHeader = new WSSecHeader();
    secHeader.setMustUnderstand(false);
    secHeader.insertSecurityHeader(doc);

    List<WSEncryptionPart> references = new ArrayList<WSEncryptionPart>();
    references.add(new WSEncryptionPart("TS-1"));

    references.add(encryptPartForRequest(requestType));

    builder.setParts(references);
    Document signedDoc = builder.build(doc, crypto, secHeader);
    return XMLUtils.PrettyDocumentToString(signedDoc);
  }

  public static String addEncryption(String document, Crypto crypto,
                                     String requestType) throws Exception
  {
    WSSecEncrypt builder = new WSSecEncrypt();
    builder.setUserInfo("vbms_server_key", "importkey");
    Document doc = getSOAPDoc(document);
    WSSecHeader secHeader = new WSSecHeader();
    secHeader.insertSecurityHeader(doc);
    List<WSEncryptionPart> references = new ArrayList<WSEncryptionPart>();

    references.add(encryptPartForRequest(requestType));

    builder.setParts(references);
    Document encryptedDoc = builder.build(doc, crypto, secHeader);
    return XMLUtils.PrettyDocumentToString(encryptedDoc);
  }

  public static WSEncryptionPart encryptPartForRequest(String requestType) {
      if (requestType.equals("uploadDocumentWithAssociations")) {
        return new WSEncryptionPart("document", VBMS_NAMESPACE, "Element");
      } else {
        return new WSEncryptionPart("Body", SOAP_NAMESPACE, "Content");
      }
  }

  private static Properties loadCryptoProperties(String keyfile) throws IOException {
    Properties properties = new Properties();
    InputStream propertiesStream = EncryptSOAPDocument.class.getResourceAsStream(TEST_PROPERTIES);
    if (propertiesStream == null) {
      throw new RuntimeException("Unable to load " + TEST_PROPERTIES + ". Is it in your classpath?");
    }
    properties.load(propertiesStream);
    properties.setProperty("org.apache.ws.security.crypto.merlin.keystore.file", keyfile);
    return properties;
  }
  
  private static void printUsage() {
    System.err.println("java EncryptSOAPDocument INFILE KEYFILE KEYPASS REQUESTNAME");
  }

  // Properties file with default crypto configuration for the test environment.
  private static final String TEST_PROPERTIES = "vbms_test.properties";
}
