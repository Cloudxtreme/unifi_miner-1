#!/usr/bin/perl
#
#  (C) sadman@sfi.komi.com 2015
#  tanx to Jakob Borg (https://github.com/calmh/unifi-api) for some methods and ideas 
#
#  Experimental!
#
#BEGIN { $ENV{PERL_JSON_BACKEND} = 'JSON::XS' };
use strict;
use warnings;
#use 5.010;
use JSON qw ();
#use JSON::XS;
#use IO::Socket::SSL;
use LWP qw ();
use Getopt::Std;
use Digest::MD5 qw(md5_hex);
use File::stat;


use constant {
     ACT_COUNT => 'count',
     ACT_SUM => 'sum',
     ACT_GET => 'get',
     ACT_DISCOVERY => 'discovery',
     CONTROLLER_VERSION_2 => 'v2',
     CONTROLLER_VERSION_3 => 'v3',
     CONTROLLER_VERSION_4 => 'v4',
     DEBUG_LOW => 1,
     DEBUG_MID => 2,
     DEBUG_HIGH => 3,
     KEY_ITEMS_NUM => 'items_num',
     MINER_VERSION => '0.99999',
     MSG_UNKNOWN_CONTROLLER_VERSION => "Version of controller is unknown: ",
     OBJ_USW => 'usw',
     OBJ_UPH => 'uph',
     OBJ_UAP => 'uap',
     OBJ_USG => 'usg',
     OBJ_WLAN => 'wlan',
     OBJ_USER => 'user',

     TRUE => 1,
     FALSE => 0,

};


sub getJSON;
sub unifiLogin;
sub unifiLogout;
sub fetchData;
sub fetchDataFromController;
sub lldJSONGenerate;
sub getMetric;
sub convert_if_bool;
sub matchObject;

my %options;
getopts("a:c:d:i:k:l:m:n:o:p:s:u:v:", \%options);


#########################################################################################################################################
#
#  Default values for global scope
#
#########################################################################################################################################
my $globalConfig = {
   # Default action for objects metric
   action => ACT_GET,
   # How much time live cache data. Use 0 for disabling cache processes
   cachetimeout => 60,
   # Where are store cache file. Better place is RAM-disk
   cacheroot=> '/run/shm', 
   # Debug level 
   debug => 0,
   # Where are controller answer. See value of 'unifi.https.port' in /opt/unifi/data/system.properties
   location => "https://127.0.0.1:8443", 
   # Operation object. wlan is exist in any case
   object => OBJ_WLAN, 
   # Name of your site 
   sitename => "default", 
   # who can read data with API
   username => "stat",
   # His pass
   password => "stat",
   # UniFi controller version
   version => CONTROLLER_VERSION_4
  };


# Rewrite default values by command line arguments
$globalConfig->{action}       = $options{a} if defined $options{a};
$globalConfig->{cachetimeout} = $options{c} if defined $options{c};
$globalConfig->{debug}        = $options{d} if defined $options{d};
$globalConfig->{id}           = $options{i} if defined $options{i};
$globalConfig->{key}          = $options{k} if defined $options{k};
$globalConfig->{location}     = $options{l} if defined $options{l};
$globalConfig->{mac}          = $options{m} if defined $options{m};
$globalConfig->{null_char}    = $options{n} if defined $options{n};
$globalConfig->{object}       = $options{o} if defined $options{o};
$globalConfig->{password}     = $options{p} if defined $options{p};
$globalConfig->{sitename}     = $options{s} if defined $options{s};
$globalConfig->{username}     = $options{u} if defined $options{u};
$globalConfig->{version}      = $options{v} if defined $options{v};

if ($globalConfig->{debug})
  {
    use Data::Dumper;
  }

# Set controller version specific data

if ($globalConfig->{version} eq CONTROLLER_VERSION_4) {
       $globalConfig->{api_path}="$globalConfig->{location}/api/s/$globalConfig->{sitename}";
       $globalConfig->{login_path}="$globalConfig->{location}/api/login";
       $globalConfig->{logout_path}="$globalConfig->{location}/logout";
       $globalConfig->{login_data}="{\"username\":\"$globalConfig->{username}\",\"password\":\"$globalConfig->{password}\"}";
       $globalConfig->{login_type}='json';
     }
elsif ($globalConfig->{version} eq CONTROLLER_VERSION_3) {
       $globalConfig->{api_path}="$globalConfig->{location}/api/s/$globalConfig->{sitename}";
       $globalConfig->{login_path}="$globalConfig->{location}/login";
       $globalConfig->{logout_path}="$globalConfig->{location}/logout";
       $globalConfig->{login_data}="username=$globalConfig->{username}&password=$globalConfig->{password}&login=login";
       $globalConfig->{login_type}='x-www-form-urlencoded';
     }
elsif ($globalConfig->{version} eq CONTROLLER_VERSION_2) {
       $globalConfig->{api_path}="$globalConfig->{location}/api";
       $globalConfig->{login_path}="$globalConfig->{location}/login";
       $globalConfig->{logout_path}="$globalConfig->{location}/logout";
       $globalConfig->{login_data}="username=$globalConfig->{username}&password=$globalConfig->{password}&login=login";
       $globalConfig->{login_type}='x-www-form-urlencoded';
     }
else      
     {
        die MSG_UNKNOWN_CONTROLLER_VERSION, $globalConfig->{version};
     }

print "\n[#]   Global config data:\n\t", Dumper $globalConfig if ($globalConfig->{debug} >= DEBUG_MID);
my $res;

# First - check for object name
if ($globalConfig->{object}) {
   # Ok. Name is exist. How about key?
   if ($globalConfig->{key}){
       # Key is given - get metric. 
       # if $globalConfig->{id} is exist then metric of this object has returned. 
       # If not calculate $globalConfig->{action} for all items in objects list (all object of type = 'object name', for example - all 'uap'
       $res=getMetric($globalConfig, fetchData($globalConfig), $globalConfig->{key}, 1);
     }
   else
     { 
       # Key is null - generate LLD-like JSON
       $res=lldJSONGenerate($globalConfig, fetchData($globalConfig));
     }
}

# Value could be 'null'. {null_char} is defined - replace null to that. 
if (defined($globalConfig->{null_char}))
 { 
   $res = $res ? $res : $globalConfig->{null_char};
 }
print "\n" if  ($globalConfig->{debug} >= DEBUG_LOW);
$res="" unless defined ($res);
# Put result of work to stdout
print  "$res\n";

##################################################################################################################################
#
#  Subroutines
#
##################################################################################################################################

#
# 
#
sub getMetric{
    # $_[0] - GlobalConfig
    # $_[1] - array/hash with info
    # $_[2] - key
    # $_[3] - dive level
    print "\n[>] ($_[3]) getMetric started" if ($_[0]->{debug} >= DEBUG_LOW);
    my $result;
    my $paramValue;
    my $tableName;
    my $key=$_[2];
    my $fKey;
    my $fValue;
    my @fData=();
    my $fDataSize=0;
    my $fStr;
    my $objList;
    my $nCnt;

    print "\n[#]   options: key='$_[2]' action='$_[0]->{action}'" if ($_[0]->{debug} >= DEBUG_MID);
    print "\n[+]   incoming object info:'\n\t", Dumper $_[1] if ($_[0]->{debug} >= DEBUG_HIGH);

    ($tableName, $key) = split(/[.]/, $key, 2);
    # if key is not defined after split (no comma in key) that mean no table name exist in incoming key and key is first and only one part of splitted data
    if (! defined($key)) 
      { $key = $tableName; undef $tableName;}
    else
      {
        # check for [filterkey=value&filterkey=value&...] construction in tableName. If that exist - key filter feature will enabled
        # regexp matched string placed into $1 and $1 listed as $fStr
        ($fStr) = $tableName =~ m/^\[([\w]+=.+&{0,1})+\]/;
        # ($fStr) = $tableName =~ m/^\[(.+)\]/;
        if ($fStr) 
          {
             # filterString is exist - need to split its to key=value pairs with '&' separator
             my @fStrings = split('&', $fStr);
             # after splitting split again - to key and values. And store it.
             for ($nCnt=0; $nCnt < @fStrings; $nCnt++) {
                # regexp with key=value format checking
                # ($fKey, $fValue) = $fStr =~ m/([-_\w]+)=([-_\w\x20]+)/gi;
                # split pair with '=' separator
                ($fKey, $fValue) = split('=', $fStrings[$nCnt]);
                # if key/value splitting was correct - save filter data into hash
                push(@fData, {key=>$fKey, val=> $fValue}) if (defined($fKey) && defined($fValue));
            }
           # flush tableName's value if tableName is represent filter-key
           undef $tableName;
          }
    }


    # Checking for type of $_[1].
    # Array must be explored for key value in each element
    # if $_[0] is array...
    if (ref($_[1]) eq 'ARRAY') 
       {
         $objList=@{$_[1]};
         print "\n[.] Array with ", $objList, " objects detected" if ($_[0]->{debug} >= DEBUG_MID);
         # if metric ask "how much items (AP's for example) in all" - just return array size (previously calculated in $result) and do nothing more
         if ($key eq KEY_ITEMS_NUM) 
            {
               $result=$objList;  
            }
         else
           {
             $result=0; 
             print "\n[.] taking value from all sections" if ($_[0]->{debug} >= DEBUG_MID);
             for ($nCnt=0; $nCnt < $objList; $nCnt++ ) {
                  # init $paramValue for right actions doing
                  if (@fData && (!matchObject($_[1][$nCnt], \@fData))) { next; }
                  $paramValue=undef;
                  # If need to analyze elements in subtable...
                  # $tableName=something mean that subkey exist
                  if ($tableName) { 
                      # Do recursively calling getMetric func with subtable and subkey and get value from it
                      $paramValue=getMetric($_[0], $_[1][$nCnt]->{$tableName}, $key, $_[3]+1); 
                    }
                 else {
                      # Do recursively calling getMetric func with that table get value of key
                      $paramValue=getMetric($_[0], $_[1][$nCnt], $key, $_[3]+1); 
                    }

                  if (defined($paramValue))
                     {
                        # need to fix trying sum of not numeric values
                        # do some math with value - sum or count               
                        if ($_[0]->{action} eq ACT_SUM)
                          {
                            $result+=$paramValue;
                          }
                        elsif ($_[0]->{action} eq ACT_COUNT)
                          {
                            $result++;
                          }
                        else 
                          {
                            # Otherwise (ACT_GET option) - take value and go out from loop
                           $result=convert_if_bool($paramValue);
                           last;
                          }
                  }
                  print "\n[.] Value=$paramValue, result=$result" if ($_[0]->{debug} >= DEBUG_HIGH);
              }#foreach;
           }
       }
    else 
       {
         # it is not array. Just get metric value by hash index
         print "\n[.] Just one object detected - get metric." if ($_[0]->{debug} >= DEBUG_MID);
         # Subtable can be not exist as vap_table for UAPs which is powered off.
         # In this case $result must be undefined for properly processed on previous dive level if subroutine is called recursively              
#         $result=undef;
         # Apply filter-key to current object or pass inside if no filter defined
         if ((!@fData) || matchObject($_[1], \@fData))            {
              print "\n[.] Object is good" if ($_[0]->{debug} >= DEBUG_MID);
              if ($tableName && defined($_[1]->{$tableName})) 
                 {
                   # if subkey was detected (tablename is given an exist) - do recursively calling getMetric func with subtable and subkey and get value from it
                   print "\n[.] It's object. Go inside" if ($_[0]->{debug} >= DEBUG_MID);
                   $result=getMetric($_[0], $_[1]->{$tableName}, $key, $_[3]+1); 
                 } 
              elsif (defined($_[1]->{$key}))
                 {
                   # Otherwise - just return value for given key
                   print "\n[.] It's key. Take value" if ($_[0]->{debug} >= DEBUG_MID);
                   $result=convert_if_bool($_[1]->{$key});
              } else {
              print "\n[.] No key or table exist :(" if ($_[0]->{debug} >= DEBUG_MID);
              }
            }
       }

 print "\n[>] ($_[3]) getMetric finished (" if ($_[0]->{debug} >= DEBUG_LOW);
 print $result if ($_[0]->{debug} >= DEBUG_LOW && defined($result));
 print ")" if ($_[0]->{debug} >= DEBUG_LOW);
 
  return $result;
}

#####################################################################################################################################
#
#  
#
#####################################################################################################################################
sub matchObject {
   # $_[0] - tested object
   # $_[1] - filter data array
   # Init match counter
   my $matchCount=0;
   my $result=TRUE;
   my $objListLen=@{$_[1]};
   if ($objListLen) {
      for (my $i=0; $i < $objListLen; $i++ ) {
        $matchCount++ if (defined($_[0]->{$_[1][$i]->{key}}) && ($_[0]->{$_[1][$i]->{key}} eq $_[1][$i]->{val}));
      }
      $result=FALSE unless ($matchCount == $objListLen);
   }
   return $result;
}



#####################################################################################################################################
#
#  Return 1/0 instead true/false if variable type is bool and return untouched value, if not
#
#####################################################################################################################################
sub convert_if_bool {
   # $_[0] - tested variable
   # if type is boolean, convert true/false || 1/0 => 1/0 with casts to a number by math operation.
   if (JSON::is_bool($_[0]))
     { return $_[0]+0 }
   else
     { return $_[0] }
}

#####################################################################################################################################
#
#  Fetch data from cache or call fetching from controller. Renew cache files.
#
#####################################################################################################################################
sub fetchData {
   # $_[0] - $GlobalConfig
   print "\n[+] fetchData started" if ($_[0]->{debug} >= DEBUG_LOW);
   print "\n[#]   options:  object='$_[0]->{object}'," if ($_[0]->{debug} >= DEBUG_MID);
   print " id='$_[0]->{id}'," if ($_[0]->{debug} >= DEBUG_MID && $_[0]->{id});
   print " mac='$_[0]->{mac}'," if ($_[0]->{debug} >= DEBUG_MID && $_[0]->{mac});
   my $result;
   my $now=time();
   my $cacheExpire=FALSE;
   my $objPath;
   my $checkObjType=TRUE;
   my $fh;
   my $jsonData;
   my $v4RapidWay=FALSE;
   my $tmpCacheFileName;
   #
   my $objectName=$_[0]->{object};

   # forming path to objects store
   if ($objectName eq OBJ_WLAN) 
      { $objPath="$_[0]->{api_path}/list/wlanconf"; $checkObjType=FALSE; }
   elsif ($objectName eq OBJ_UAP || $objectName eq OBJ_USW || $objectName eq OBJ_USG || $objectName eq OBJ_UPH)
      { $objPath="$_[0]->{api_path}/stat/device"; }
   elsif ($objectName eq OBJ_USER)
      { $objPath="$_[0]->{api_path}/stat/sta"; $checkObjType=FALSE; }
    else { die "[!] Unknown object given"; }

   if (($_[0]->{version} eq CONTROLLER_VERSION_4) && ($objectName eq OBJ_UAP) && $_[0]->{mac})  
      {
         $objPath.="/$_[0]->{mac}"; $v4RapidWay=TRUE;
      }
   print "\n[.] Object path: $objPath\n" if ($_[0]->{debug} >= DEBUG_MID);

   # if cache timeout setted to 0 then no try to read/update cache - fetch data from controller
   if ($_[0]->{cachetimeout} != 0)
      {
         my $cacheFileName = $_[0]->{cacheroot} .'/'. md5_hex($objPath);
         print "\n[.] Cache file name: $cacheFileName\n" if ($_[0]->{debug} >= DEBUG_MID);
         # Cache file is exist and non-zero size?
         if (-e $cacheFileName && -s $cacheFileName)
            # Yes, is exist.
            # If cache is expire...
            { $cacheExpire = TRUE if ((stat($cacheFileName)->mtime + $_[0]->{cachetimeout}) < $now) }
            # Cache file is not exist => cache is expire => need to create
         else
            { $cacheExpire = TRUE; }

         # Cache expire - need to update
         if ($cacheExpire)
            {
               print "\n[.] Cache expire or not found. Renew..." if ($_[0]->{debug} >= DEBUG_MID);
               # here we need to call login/fetch/logout chain
               $jsonData=fetchDataFromController($_[0], $objPath);
               #
               $tmpCacheFileName=$cacheFileName . ".tmp";
               print "\n[.]   temporary cache file=$tmpCacheFileName" if ($_[0]->{debug} >= DEBUG_MID);
               open ($fh, "+>", $tmpCacheFileName) or die "Could not write to $tmpCacheFileName";
               chmod 0666, $fh;
#               sysopen ($fh,$cacheFileName, O_RDWR|O_CREAT|O_TRUNC, 0777) or die "Could not write to $cacheFileName";
               # lock file for monopoly mode write and push data
               # can i use O_EXLOCK flag into sysopen?

               # if script can lock cache temp file - write data, close and rename it to proper name
               if (flock ($fh, 2))
                  {
#                     print $fh $coder->encode($jsonData);
                     print $fh JSON::encode_json($jsonData);
                     close $fh;
                     rename $tmpCacheFileName, $cacheFileName;
                  }
               else
                  {
                     # can't lock - just close and use fetched json data for work
                     close $fh;
                  }

            }
          else
            {
               open ($fh, "<", $cacheFileName) or die "Can't open $cacheFileName";
               # read data from file
               $jsonData=JSON::decode_json(<$fh>);
#               $jsonData=$coder->decode(<$fh>);
               # close cache
               close $fh;
            }
        }
    else
      {
         print "\n[.] No read/update cache because cache timeout = 0" if ($_[0]->{debug} >= DEBUG_MID);
         $jsonData=fetchDataFromController($_[0],$objPath);
      }
   # When going by rapid way only one object is fetched
   if ($v4RapidWay) 
      { 
        print "\n[.] Rapidway allowed" if ($_[0]->{debug} >= DEBUG_MID);
        $result=@{$jsonData}[0];
      }
   else
     {
       # Lets analyze JSON 
       foreach my $jsonObject (@{$jsonData}) {
          # ID is given?
          if ($_[0]->{id})
          {

             # Object with given ID is found, jump out to end of function
             # UBNT Phones use 'device_id' key for ID store ID (?)
             if (($objectName eq OBJ_UPH) && ($jsonObject->{'device_id'} eq $_[0]->{id}))
                { $result=$jsonObject; last; }
             elsif 
                ( $jsonObject->{'_id'} eq $_[0]->{id}) { $result=$jsonObject; last; }
          } 

          # Workaround for object without type key (WLAN for example)
          $jsonObject->{type}=$_[0]->{object} if (! $checkObjType);

          # Right type of object?
          if ($jsonObject->{type} eq $_[0]->{object}) 
             { 
               # Collect all object with given type
               { push (@{$result}, $jsonObject); }
             } # if ... type
      } # foreach jsonData
     }
   print "\n[<]   fetched data:\n\t", Dumper $result if ($_[0]->{debug} >= DEBUG_HIGH);
   print "\n[-] fetchDataFromController finished" if ($_[0]->{debug} >= DEBUG_LOW);
   return $result;
}

#####################################################################################################################################
#
#  Fetch data from from controller.
#
#####################################################################################################################################
sub fetchDataFromController {
   # $_[0] - GlobalConfig
   # $_[11 - object path
   #
   print "\n[+] fetchDataFromController started" if ($_[0]->{debug} >= DEBUG_LOW);
   print "\n[*] Login into UniFi controller" if ($_[0]->{debug} >= DEBUG_LOW);

   # HTTP UserAgent init
   # Set SSL_verify_mode=off to login without certificate manipulation
   # SSL_verify_mode => 0 eq SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE ?
   my $ua = LWP::UserAgent-> new(cookie_jar => {}, agent => "UniFi Miner/" . MINER_VERSION . " (perl engine)",
                                 ssl_opts => {SSL_verify_mode => 0, verify_hostname => 0});
   unifiLogin($_[0], $ua);

   my $result=getJSON($_[0], $ua, $_[1]);
   #print "\n[<]   recieved from JSON requestor:\n\t $result" if $_[0]->{debug} >= DEBUG_HIGH;

   print "\n[*] Logout from UniFi controller" if  ($_[0]->{debug} >= DEBUG_LOW);
   unifiLogout($_[0], $ua);
   print "\n[-] fetchDataFromController finished" if ($_[0]->{debug} >= DEBUG_LOW);
   return $result;
}

#####################################################################################################################################
#
#  Generate LLD-like JSON using fetched data
#
#####################################################################################################################################
sub lldJSONGenerate{
    # $_[0] - $GlobalConfig
    # $_[1] - array/hash with info
    print "\n[+] lldJSONGenerate started" if ($_[0]->{debug} >= DEBUG_LOW);
    print "\n[#]   options: object='$_[0]->{object}'" if ($_[0]->{debug} >= DEBUG_MID);
    my $lldData;
    my $resut;
    my $lldItem = 0;
    my $objectName=$_[0]->{object};
    # if $_[1] is array...
    if (ref($_[1]) eq 'ARRAY') 
       {
         foreach my $jsonObject (@{$_[1]}) {
           if ($objectName eq OBJ_WLAN) {
               $lldData->{'data'}->[$lldItem]->{'{#ALIAS}'}=$jsonObject->{'name'};
               $lldData->{'data'}->[$lldItem]->{'{#ID}'}=$jsonObject->{'_id'};
               $lldData->{'data'}->[$lldItem]->{'{#ISGUEST}'}=convert_if_bool($jsonObject->{'is_guest'});
#               $lldData->{'data'}->[$lldItem]->{'{#ISGUEST}'}=$hashRef->{'is_guest'};

           }
           elsif ($objectName eq OBJ_USER ) {
              $lldData->{'data'}->[$lldItem]->{'{#NAME}'}=$jsonObject->{'hostname'};
              $lldData->{'data'}->[$lldItem]->{'{#ID}'}=$jsonObject->{'_id'};
              $lldData->{'data'}->[$lldItem]->{'{#IP}'}=$jsonObject->{'ip'};
              $lldData->{'data'}->[$lldItem]->{'{#MAC}'}=$jsonObject->{'mac'};
              # sometime {'hostname'} may be null. UniFi controller replace that hostnames by {'mac'}
              $lldData->{'data'}->[$lldItem]->{'{#NAME}'}=$lldData->{'data'}->[$lldItem]->{'{#MAC}'} unless defined ($lldData->{'data'}->[$lldItem]->{'{#NAME}'});

               $lldData->{'data'}->[$lldItem]->{'{#ISGUEST}'}=convert_if_bool($jsonObject->{'is_guest'});
               $lldData->{'data'}->[$lldItem]->{'{#AUTHORIZED}'}=convert_if_bool($jsonObject->{'authorized'});
           }
           elsif ($objectName eq OBJ_UPH ) {
              $lldData->{'data'}->[$lldItem]->{'{#ID}'}=$jsonObject->{'device_id'};
              $lldData->{'data'}->[$lldItem]->{'{#IP}'}=$jsonObject->{'ip'};
              $lldData->{'data'}->[$lldItem]->{'{#MAC}'}=$jsonObject->{'mac'};
              # state of object: 0 - off, 1 - on
              $lldData->{'data'}->[$lldItem]->{'{#STATE}'}=$jsonObject->{'state'};
           }
           elsif ($objectName eq OBJ_UAP || $objectName eq OBJ_USG || $objectName eq OBJ_USW) {
              $lldData->{'data'}->[$lldItem]->{'{#ALIAS}'}=$jsonObject->{'name'};
              $lldData->{'data'}->[$lldItem]->{'{#ID}'}=$jsonObject->{'_id'};
              $lldData->{'data'}->[$lldItem]->{'{#IP}'}=$jsonObject->{'ip'};
              $lldData->{'data'}->[$lldItem]->{'{#MAC}'}=$jsonObject->{'mac'};
              # state of object: 0 - off, 1 - on
              $lldData->{'data'}->[$lldItem]->{'{#STATE}'}=$jsonObject->{'state'};

           }
           $lldItem++;
         } #foreach;
      }
    # Just one object selected, need generate LLD with keys from subtable (USW for example)
    else
      {
        if ($objectName eq OBJ_USW) {
         foreach my $jsonObject (@{$_[0]->{port_table}}) {
            $lldData->{'data'}->[$lldItem]->{'{#ALIAS}'}=$jsonObject->{'name'};
            $lldData->{'data'}->[$lldItem]->{'{#PORTIDX}'}="$jsonObject->{'port_idx'}";
            $lldItem++;
         }
         }
      }

#  For JSON::PP (use JSON / use JSON:PP)
#    $resut=encode_json($lldData, {utf8 => 1, pretty => 1});
    $resut=JSON::encode_json($lldData);

#    my $coder = JSON::XS->new->ascii->pretty->allow_nonref;
#    $resut=$coder->encode ($lldData);

    print "\n[<]   generated lld:\n\t", Dumper $resut if ($_[0]->{debug} >= DEBUG_HIGH);
    print "\n[-] lldJSONGenerate finished" if ($_[0]->{debug} >= DEBUG_LOW);
    return $resut;
}

#####################################################################################################################################
#
#  Authenticate against unifi controller
#
#####################################################################################################################################
sub unifiLogin {
   # $_[0] - GlobalConfig
   # $_[1] - user agent
   print "\n[>] unifiLogin started" if ($_[0]->{debug} >= DEBUG_LOW);
   print "\n[#]  options path='$_[0]->{login_path}' type='$_[0]->{login_type}' data='$_[0]->{login_data}'" if ($_[0]->{debug} >= DEBUG_MID);
   my $response=$_[1]->post($_[0]->{login_path}, 'Content_type' => "application/$_[0]->{login_type}", 'Content' => $_[0]->{login_data});
   print "\n[<]  HTTP respose:\n\t", Dumper $response if ($_[0]->{debug} >= DEBUG_HIGH);

   if ($_[0]->{version} eq CONTROLLER_VERSION_4) 
      {
         # v4 return 'Bad request' (code 400) on wrong auth
         die "\n[!] Login error:" if ($response->code eq '400');
         # v4 return 'OK' (code 200) on success login and must die only if get error
         die "\n[!] Other HTTP error:", $response->code if ($response->is_error);
      }
   elsif ($_[0]->{version} eq CONTROLLER_VERSION_3) {
        # v3 return 'OK' (code 200) on wrong auth
        die "\n[!] Login error:", $response->code if ($response->is_success );
        # v3 return 'Redirect' (code 302) on success login and must die only if code<>302
        die "\n[!] Other HTTP error:", $response->code if ($response->code ne '302');
      }
   else {
      # v2 code
      ;
       }
   print "\n[-] unifiLogin finished successfully" if ($_[0]->{debug} >= DEBUG_LOW);
   return  $response->code;
}

#####################################################################################################################################
#
#  Close session 
#
#####################################################################################################################################
sub unifiLogout {
   # $_[0] - GlobalConfig
   # $_[1] - user agent
   print "\n[+] unifiLogout started" if ($_[0]->{debug} >= DEBUG_LOW);
   my $response=$_[1]->get($_[0]->{logout_path});
   print "\n[-] unifiLogout finished" if ($_[0]->{debug} >= DEBUG_LOW);
}

#####################################################################################################################################
#
#  Take JSON from controller via HTTP  
#
#####################################################################################################################################
sub getJSON {
   # $_[0] - GlobalConfig
   # $_[1] - user agent
   # $_[2] - uri string
   print "\n[+] getJSON started" if ($_[0]->{debug} >= DEBUG_LOW);
   print "\n[#]   options url=$_[1]" if ($_[0]->{debug} >= DEBUG_MID);
   my $response=$_[1]->get($_[2]);
   # if request is not success - die
   die "[!] JSON taking error, HTTP code:", $response->status_line unless ($response->is_success);
   print "\n[<]   fetched data:\n\t", Dumper $response->decoded_content if ($_[0]->{debug} >= DEBUG_HIGH);
   my $result=JSON::decode_json($response->decoded_content);
#   my $result=from_json($response->decoded_content,{convert_blessed => 0, utf8 => 1});
   my $jsonData=$result->{data};
   my $jsonMeta=$result->{meta};
   # server answer is ok ?
   if ($jsonMeta->{'rc'} eq 'ok') 
      { 
        print "\n[-] getJSON finished successfully" if ($_[0]->{debug} >= DEBUG_LOW);
        return $jsonData;    
      }
   else
      { die "[!] getJSON error: rc=$jsonMeta->{'rc'}"; }
}
