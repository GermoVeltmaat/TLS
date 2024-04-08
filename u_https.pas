Unit u_https;
{ QaD unit for retrieving secure web content

  Copyright (C) 2024 Germo Veltmaat  programmer@germo.eu

  This library is free software; you can redistribute it and/or modify it
  under the terms of the GNU Library General Public License as published by
  the Free Software Foundation; either version 2 of the License, or (at your
  option) any later version.

  This program is distributed in the hope that it will be useful, but WITHOUT
  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU Library General Public License
  for more details.

  You should have received a copy of the GNU Library General Public License
  along with this library; if not, write to the Free Software Foundation,
  Inc., 51 Franklin Street - Fifth Floor, Boston, MA 02110-1335, USA.
}

{$mode objfpc}{$H+}
Interface
Uses
  SysUtils,
  Classes,
  uTCPS;

Type
{ THtppsGetClient }

  THtppsGetClient = Class(TTCPSClient)
  private // request deel
    FHost    : String;
    FUrl     : String;
    FPort    : Integer;
    FTimeOut : LongWord;
    FSendHeaders : TStringList;

  private // ontvang deel
    FEndTime    : QWord;
    FRecvBuffer : TMemoryStream;
    Procedure StartTiming(TimeOut : QWord);
    Function  TimeOut : Boolean;
    Function  Lees1Regel : String;
    Function  RestSize : Integer;

  Private // response deel
    FRespVersion : LongWord;
    FRespStatus  : LongWord;
    FRespReason  : String;
    FRespHeaders : TStringList;
    FResponse    : TMemoryStream;
    procedure DoVerify (Sender : TObject; Flags : LongWord; var Allow : boolean);
    procedure DoAppRead (Sender : TObject; Buf : pointer; len : cardinal);

  Public
    Constructor Create;
    Destructor  Destroy; Override;
    Property    Host        : String      Read FHost        Write FHost;
    Property    URL         : String      Read FUrl         Write FUrl;
    Property    Port        : Integer     Read FPort        Write FPort;
    Property    TimeOutms   : LongWord    Read FTimeOut     Write FTimeOut;
    Property    SendHeaders : TStringList Read FSendHeaders;

// Procedure to execute GET command with data in request part (host, etc ..)
// Result is ONLY that connection was made, and response is received. NOT what kind of response
    Function GetIt : Boolean;
// convenience procedure
    Function Get( AskHost, AskUrl : String;
                  Askheaders : TStringList = nil;
                  AskPort : Integer = 443) : Boolean;
// response values
    Property RespVersion : LongWord    Read FRespVersion; // HTTP version
    Property RespStatus  : LongWord    Read FRespStatus;  // HTTP response status (200, etc)
    Property RespReason  : String      Read FRespReason;  // HTTP response (OK, etc)
    Property RespHeaders : TStringList Read FRespHeaders; // response headers

    Property Response    : TMemoryStream Read FResponse;  // response in stream
    Function ResponseAsString : String;                   // response as string

    End;


Implementation
Uses
  HTTP
// extra code for logging switch
{$IFDEF ExternalLog}
  ,u_log;
{$ELSE}
  ; Procedure LOG(Tekst : String); Begin End;
{$ENDIF}


{ THtppsGetClient }
// create object and reset all variables
Constructor Thtppsgetclient.Create;
Begin
  Inherited Create;
  FHost    := '';
  FUrl     := '';
  FPort    := 443;
  FTimeOut := 60000;
  FRecvBuffer  := TMemoryStream.Create;
  FSendHeaders := TStringList.Create;
  FRespVersion := 0;
  FRespStatus  := 0;
  FRespReason  := '';
  FRespHeaders := TStringList.Create;
  FResponse    := TMemoryStream.Create;
  OnVerify     := @DoVerify;
  OnAppRead    := @DoAppRead;
  End;

// clean up this object
Destructor Thtppsgetclient.Destroy;
Begin
  FreeAndNil(FRecvBuffer);
  FreeAndNil(FSendHeaders);
  FreeAndNil(FRespHeaders);
  FreeAndNil(FResponse);
  Inherited Destroy;
  End;

// helper function to yes/no accept connection
Procedure Thtppsgetclient.Doverify(Sender : Tobject; Flags : Longword; Var Allow : Boolean);
var
  Reasons : TStringList;
  Reason : String;
begin
  if Flags <> 0 then Begin
    Reasons := TTCPSClient (Sender).Issues (Flags);
    for Reason In Reasons do Log('  ' + Reason);
    Reasons.Free;
    end;
  Allow := true;
  end;

// helper function to receive chunk of data
Procedure Thtppsgetclient.Doappread(Sender : Tobject; Buf : Pointer; Len : Cardinal);
begin
  if len <> 0 then FRecvBuffer.Write (Buf^, len);
  end;

{ complete response consist of: HTTP header, response headers, response data
  These helper functions are for splitting it }

// helper function to parse 1 string of data from complete response
Function Thtppsgetclient.Lees1regel : String;
Var
  OneByte : Byte;
Begin
  Result := '';
  Try
    While FRecvBuffer.Position < FRecvBuffer.Size Do Begin;
      OneByte := FRecvBuffer.ReadByte;
      Case OneByte of
        13 : ;      // deze ignoreren we
        10 : Exit;  // eind van regel
      Else
        Result := Result + Chr(OneByte);
        End;
      End;
  Except
    on e : Exception Do Log('Leesbyte fout ' + e.Message);
    End;
  End;

// helper function to get size of rest of response
Function Thtppsgetclient.Restsize : Integer;
Begin
  With FRecvBuffer Do
    Result := Size - Position;
  End;

{ helper functions for timeout }
// helper function set mark for start of timeout
Procedure Thtppsgetclient.Starttiming(Timeout : Qword);
Begin
  FEndTime := GetTickCount64 + Timeout;
  End;

// helper function check time is out
Function Thtppsgetclient.Timeout : Boolean;
Begin
  Result := (GetTickCount64 > FEndTime);
  End;

// main GET function
Function Thtppsgetclient.Getit : Boolean;
var
  Request : string;
  Regel : String;
  AVersion, AStatus : LongWord;
  AReason : String;

Begin
// default
  Result := False;
// resultaten leegmaken
  FRecvBuffer.Clear;
  FRespVersion := 0;
  FRespStatus  := 0;
  FRespReason  := '';
  FRespHeaders.Clear;
  FResponse.Clear;
// gegevens in goede vars in TTCPSClient zetten
  HostName := FHost;
  RemoteAddress := '';
  RemotePort := FPort;
// make a connection
  if Connect then begin
// set timeout timer
    StartTiming(FTimeOut);
// make resuest
    Request := 'GET ' + FUrl + ' HTTP/1.0' + #13#10;
    Request := Request + FSendHeaders.Text + #13#10;
    Request := Request + #13#10;
// send request
    AppWrite(Request);
// wait for response or timeout
    Repeat Sleep(10); Until Not(Connected) Or TimeOut;

// check op timeout
    If TimeOut Then Begin
      Log('Timeout');
      FRespStatus := HTTP_STATUS_REQUEST_TIMEOUT;
      Exit;
      End;

// check op iets ontvangen
    If FRecvBuffer.Size = 0 Then Begin
      Log('Niets ontvangen');
      FRespStatus := HTTP_STATUS_NO_CONTENT;
      Exit;
      End;

// start at beginning of total response
    FRecvBuffer.Position := 0;

// http header
    Regel := Lees1Regel; // LOG(Regel);
    If HTTPParseResponseLine(Regel, AVersion,AStatus,AReason) Then Begin
      FRespVersion := AVersion;
      FRespStatus := AStatus;
      FRespReason := AReason;
      End
    Else Begin
      FRespStatus := HTTP_STATUS_VERSION_NOT_SUPPORTED;
      Exit(False);
      End;

// response headers
    Repeat
      Regel := Lees1Regel; // LOG(Regel);
      If Regel <> '' Then FRespHeaders.Add(Regel);
      Until Regel = '';

// inhoud
    FResponse.CopyFrom(FRecvBuffer,RestSize);
    FResponse.Position := 0;
    end;

// everything worked out
  Result := True;
  End;

Function Thtppsgetclient.Get( Askhost, Askurl : String;
                              Askheaders : Tstringlist;
                              Askport : Integer) : Boolean;
Begin
// use parameters
  FHost := AskHost;
  FPort := AskPort;
  FUrl := Askurl;
// use send-headers (if provided)
  FSendHeaders.Clear;
  If Assigned(AskHeaders) Then
    FSendHeaders.AddStrings(Askheaders);
// Just DoIt
  Result := GetIt;
  End;

Function Thtppsgetclient.ResponseAsString : String;
Var
  RespString : TStringStream;
Begin
  RespString := TStringStream.Create;
  Try
    Try
      FResponse.Position := 0;
      RespString.CopyFrom(FResponse,FResponse.Size);
      Result := RespString.DataString;
    Except
      on E: Exception do
        LOG('Fout in copieeren : ' + E.Message);
      End;
  Finally
    FreeAndNil(RespString);
    end;
  End;

END.


